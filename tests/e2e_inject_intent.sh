#!/usr/bin/env bash
# Build OpenClaw-shaped raw session payloads (same structure as extrapolator_run_cycle),
# push via edamame_cli upsert_behavioral_model_from_raw_sessions, then verify predictions.
#
# Does not require the OpenClaw gateway or CLI. Needs a running EDAMAME host and edamame_cli.
#
# Environment:
#   EDAMAME_CLI                    Path to edamame_cli (optional)
#   E2E_OPENCLAW_AGENT_INSTANCE_ID Optional; overrides persisted ~/.edamame_openclaw_agent_instance_id
#   E2E_POLL_ATTEMPTS              Default 36 (longer soak tolerance)
#   E2E_POLL_INTERVAL_SECS         Default 5
#   E2E_STRICT_HASH                Default 0
#   E2E_DIAGNOSTICS_FILE           If set, write JSON diagnosis on poll timeout (harness sets this)
#   E2E_PROGRESS_POLL              If 1, print missing keys to stderr during polls (noisy)
#   E2E_SKIP_REPO_VERSION_CHECK    If 1, skip package.json vs openclaw.plugin.json version alignment
#   E2E_SKIP_PROVISION_STRICT      If 1, skip installed-plugin check and use repo copy
#   E2E_REQUIRE_PAIRING            If 1, fail when only legacy PSK exists (no pairing PSK)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${OPENCLAW_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

POLL_ATTEMPTS="${E2E_POLL_ATTEMPTS:-36}"
POLL_INTERVAL="${E2E_POLL_INTERVAL_SECS:-5}"
LAST_RAW_OUT=""

resolve_edamame_cli() {
  if [[ -n "${EDAMAME_CLI:-}" && -x "$EDAMAME_CLI" ]]; then
    printf '%s' "$EDAMAME_CLI"
    return 0
  fi
  if command -v edamame_cli >/dev/null 2>&1; then
    command -v edamame_cli
    return 0
  fi
  if command -v edamame-cli >/dev/null 2>&1; then
    command -v edamame-cli
    return 0
  fi
  local candidates=(
    "$REPO_ROOT/../edamame_cli/target/release/edamame_cli"
    "$REPO_ROOT/../edamame_cli/target/debug/edamame_cli"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

EDA_CLI="$(resolve_edamame_cli || true)"
if [[ -z "${EDA_CLI:-}" ]]; then
  echo "FAIL: edamame_cli not found. Set EDAMAME_CLI or build ../edamame_cli" >&2
  exit 1
fi
echo "OK: edamame_cli $EDA_CLI"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not found" >&2
  exit 1
fi

echo "=== Provision check: installed OpenClaw plugin ==="

OPENCLAW_HOME="$HOME/.openclaw"
INSTALLED_PLUGIN="$OPENCLAW_HOME/extensions/edamame/index.ts"
INSTALLED_META="$OPENCLAW_HOME/edamame-openclaw/package.json"

if [[ "${E2E_SKIP_PROVISION_STRICT:-0}" != "1" ]]; then
  if [[ ! -f "$INSTALLED_PLUGIN" ]]; then
    echo "FAIL: installed plugin not found at $INSTALLED_PLUGIN" >&2
    echo "Run: edamame-posture install-agent-plugin openclaw (or edamame_cli rpc provision_agent_plugin)" >&2
    exit 1
  fi
  if [[ ! -f "$INSTALLED_META" ]]; then
    echo "FAIL: installed metadata not found at $INSTALLED_META" >&2
    exit 1
  fi
  export E2E_OPENCLAW_PLUGIN_ROOT="$OPENCLAW_HOME/extensions/edamame"
  echo "OK: using installed plugin at $E2E_OPENCLAW_PLUGIN_ROOT"
else
  if [[ -f "$INSTALLED_PLUGIN" ]]; then
    export E2E_OPENCLAW_PLUGIN_ROOT="$OPENCLAW_HOME/extensions/edamame"
    echo "OK: installed plugin found, using $E2E_OPENCLAW_PLUGIN_ROOT"
  else
    echo "WARN: installed plugin not found; using repo copy (E2E_SKIP_PROVISION_STRICT=1)"
    unset E2E_OPENCLAW_PLUGIN_ROOT
  fi
fi

PAIRING_PSK_FILE="$HOME/.openclaw/edamame-openclaw/state/edamame-mcp.psk"
LEGACY_PSK_FILE="$HOME/.edamame_psk"
if [[ -n "${EDAMAME_MCP_PSK:-}" ]]; then
  echo "OK: PSK from EDAMAME_MCP_PSK env"
elif [[ -s "$PAIRING_PSK_FILE" ]]; then
  echo "OK: PSK file $PAIRING_PSK_FILE (pairing)"
elif [[ -s "$LEGACY_PSK_FILE" ]]; then
  if [[ "${E2E_REQUIRE_PAIRING:-0}" == "1" ]]; then
    echo "FAIL: pairing PSK not found at $PAIRING_PSK_FILE (legacy PSK exists but E2E_REQUIRE_PAIRING=1)" >&2
    exit 1
  fi
  echo "WARN: using legacy PSK $LEGACY_PSK_FILE (pairing PSK not found at $PAIRING_PSK_FILE)"
else
  echo "FAIL: PSK not found. Run setup/pair.sh, set EDAMAME_MCP_PSK, or write ~/.edamame_psk" >&2
  exit 1
fi

if [[ "${E2E_SKIP_REPO_VERSION_CHECK:-0}" != "1" ]]; then
  echo "=== Repo manifest version alignment ==="
  export _E2E_OW_ROOT="$REPO_ROOT"
  python3 <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["_E2E_OW_ROOT"])
pkg_p = root / "package.json"
plg_p = root / "extensions" / "edamame" / "openclaw.plugin.json"
for p in (pkg_p, plg_p):
    if not p.is_file():
        print(f"FAIL: missing {p}", file=sys.stderr)
        raise SystemExit(1)
pkg = json.loads(pkg_p.read_text(encoding="utf-8"))
plg = json.loads(plg_p.read_text(encoding="utf-8"))
vp = pkg.get("version")
vl = plg.get("version")
if not vp or not vl:
    print("FAIL: package.json or openclaw.plugin.json missing version field", file=sys.stderr)
    raise SystemExit(1)
if vp != vl:
    print(
        f"FAIL: version mismatch package.json={vp} extensions/edamame/openclaw.plugin.json={vl}",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(f"OK: OpenClaw bundle version {vp} (package + plugin manifest)")
PY
  unset _E2E_OW_ROOT
fi

echo "=== Build payload and push via MCP (OpenClaw plugin) ==="
(cd "$REPO_ROOT" && npm ci 2>&1) || echo "WARN: npm ci failed, continuing with existing node_modules"
export E2E_PUSH_VIA_MCP=1
set +e
E2E_JSON="$(cd "$REPO_ROOT" && node --import tsx ./scripts/e2e_build_openclaw_payload.mts 2>&1)"
BUILD_CODE=$?
set -e
if [[ "$BUILD_CODE" != 0 ]]; then
  echo "$E2E_JSON"
  echo "FAIL: payload build/push exited $BUILD_CODE" >&2
  exit 1
fi
AGENT_ID="$(echo "$E2E_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['agent_instance_id'])")"
MARKERS_CSV="$(echo "$E2E_JSON" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin)['session_keys']))")"
MCP_RESULT="$(echo "$E2E_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mcp_result',''))")"

echo "agent_instance_id=$AGENT_ID"
echo "session_keys=$MARKERS_CSV"
echo "MCP upsert result: $MCP_RESULT"

if echo "$MCP_RESULT" | grep -qi "ERROR"; then
  echo "FAIL: MCP upsert returned error" >&2
  exit 1
fi

WINDOW_HASH="$(echo "$MCP_RESULT" | python3 -c "
import json, sys
text = sys.stdin.read().strip()
try:
    obj = json.loads(text)
except json.JSONDecodeError:
    sys.exit(0)
if isinstance(obj, str):
    try:
        obj = json.loads(obj)
    except json.JSONDecodeError:
        sys.exit(0)
wh = obj.get('window') if isinstance(obj, dict) else None
h = (wh or {}).get('hash') if isinstance(wh, dict) else None
if h:
    print(h)
" 2>/dev/null || true)"

echo "=== Poll get_behavioral_model ==="

export _E2E_AGENT_TYPE="openclaw"
export _E2E_AGENT_ID="$AGENT_ID"
export _E2E_SESSION_KEYS="$MARKERS_CSV"
export _E2E_EXPECT_HASH="${WINDOW_HASH:-}"
export _E2E_STRICT_HASH="${E2E_STRICT_HASH:-0}"

for ((i = 1; i <= POLL_ATTEMPTS; i++)); do
  echo "--- poll $i / $POLL_ATTEMPTS ---"
  export _E2E_POLL_INDEX="$i"
  if [[ "${E2E_PROGRESS_POLL:-0}" == "1" ]]; then
    export _E2E_PROGRESS_POLL=1
  else
    unset _E2E_PROGRESS_POLL
  fi
  set +e
  RAW_OUT="$("$EDA_CLI" rpc get_behavioral_model --pretty 2>/dev/null)"
  CLI_CODE=$?
  set -e
  if [[ "$CLI_CODE" != 0 ]]; then
    echo "WARN: edamame_cli failed (exit $CLI_CODE)"
    sleep "$POLL_INTERVAL"
    continue
  fi
  LAST_RAW_OUT="$RAW_OUT"

  if python3 -c "
import json, os, re, sys

def behavioral_from_cli_output(text):
    text = text.strip()
    if not text:
        raise ValueError('empty cli output')
    m = re.match(r'Result:\\s*(.+)', text, re.S)
    payload = m.group(1).strip() if m else text.strip()
    first = json.loads(payload)
    if isinstance(first, str):
        return json.loads(first)
    return first

agent_type = os.environ['_E2E_AGENT_TYPE'].strip()
agent_id = os.environ['_E2E_AGENT_ID'].strip()
session_keys = [k.strip() for k in os.environ['_E2E_SESSION_KEYS'].split(',') if k.strip()]
expect = os.environ['_E2E_EXPECT_HASH'].strip()
strict = os.environ.get('_E2E_STRICT_HASH', '0').strip() == '1'
progress = os.environ.get('_E2E_PROGRESS_POLL', '0').strip() == '1'
poll_index = int(os.environ.get('_E2E_POLL_INDEX', '0'))
raw = sys.stdin.read()
try:
    m = behavioral_from_cli_output(raw)
except (json.JSONDecodeError, TypeError, ValueError) as exc:
    if progress:
        print(f'WARN: parse_error poll={poll_index}: {exc}', file=sys.stderr)
    sys.exit(1)
if m == {'model': None} or (len(m) == 1 and m.get('model') is None):
    if progress:
        print(f'WARN: model_null poll={poll_index}', file=sys.stderr)
    sys.exit(1)
contribs = m.get('contributors') if isinstance(m.get('contributors'), list) else []
found = None
for c in contribs:
    if c.get('agent_type') == agent_type and c.get('agent_instance_id') == agent_id:
        found = c
        break
if not found and m.get('agent_type') == agent_type and m.get('agent_instance_id') == agent_id:
    found = m
if not found:
    if progress:
        types_ids = [(c.get('agent_type'), c.get('agent_instance_id')) for c in contribs[:12]]
        print(f'WARN: no_contributor_match poll={poll_index} want=({agent_type},{agent_id}) contributors={types_ids}', file=sys.stderr)
    sys.exit(1)
h = (found.get('hash') or '').strip()
if not h:
    if progress:
        print(f'WARN: contributor_hash_empty poll={poll_index}', file=sys.stderr)
    sys.exit(1)
if strict and expect and h != expect:
    if progress:
        print(f'WARN: strict_hash_mismatch poll={poll_index} expect={expect[:24]}... got={h[:24]}...', file=sys.stderr)
    sys.exit(1)
preds = m.get('predictions') if isinstance(m.get('predictions'), list) else []
missing = []
for sk in session_keys:
    ok = any(
        p.get('agent_type') == agent_type
        and p.get('agent_instance_id') == agent_id
        and p.get('session_key') == sk
        for p in preds
    )
    if not ok:
        missing.append(sk)
if missing:
    if progress:
        ours = [p.get('session_key') for p in preds if p.get('agent_type') == agent_type and p.get('agent_instance_id') == agent_id]
        print(f'WARN: missing_session_keys poll={poll_index} missing={missing} have_count={len(ours)} sample_have={ours[:8]}', file=sys.stderr)
    sys.exit(1)
print(h)
sys.exit(0)
" <<<"$RAW_OUT"; then
    unset _E2E_AGENT_TYPE _E2E_AGENT_ID _E2E_SESSION_KEYS _E2E_EXPECT_HASH _E2E_STRICT_HASH _E2E_POLL_INDEX _E2E_PROGRESS_POLL
    echo "OK: openclaw predictions for $MARKERS_CSV"
    echo "PASS: OpenClaw-shaped raw ingest verified"
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done

unset _E2E_AGENT_TYPE _E2E_AGENT_ID _E2E_SESSION_KEYS _E2E_EXPECT_HASH _E2E_STRICT_HASH _E2E_POLL_INDEX _E2E_PROGRESS_POLL

echo "FAIL: timeout waiting for openclaw predictions (${POLL_ATTEMPTS} attempts x ${POLL_INTERVAL}s)" >&2

export _E2E_DIAG_RAW="${LAST_RAW_OUT:-}"
export _E2E_DIAG_SUITE="openclaw"
export _E2E_DIAG_AGENT_TYPE="openclaw"
export _E2E_DIAG_AGENT_ID="$AGENT_ID"
export _E2E_DIAG_SESSION_KEYS="$MARKERS_CSV"
export _E2E_DIAG_EXPECT_HASH="${WINDOW_HASH:-}"
export _E2E_DIAG_STRICT="${E2E_STRICT_HASH:-0}"
export _E2E_DIAG_ATTEMPTS="$POLL_ATTEMPTS"
export _E2E_DIAG_INTERVAL="$POLL_INTERVAL"
DIAG_OUT="$(python3 <<'PY'
import json, os, re, sys

def behavioral_from_cli_output(text):
    text = (text or "").strip()
    if not text:
        return None, "empty_cli_output"
    m = re.match(r"Result:\s*(.+)", text, re.S)
    payload = m.group(1).strip() if m else text.strip()
    try:
        first = json.loads(payload)
    except json.JSONDecodeError as exc:
        return None, f"json_decode_outer:{exc}"
    if isinstance(first, str):
        try:
            return json.loads(first), None
        except json.JSONDecodeError as exc:
            return None, f"json_decode_inner:{exc}"
    return first, None

suite = os.environ.get("_E2E_DIAG_SUITE", "")
at = os.environ.get("_E2E_DIAG_AGENT_TYPE", "").strip()
aid = os.environ.get("_E2E_DIAG_AGENT_ID", "").strip()
keys = [k.strip() for k in os.environ.get("_E2E_DIAG_SESSION_KEYS", "").split(",") if k.strip()]
expect = os.environ.get("_E2E_DIAG_EXPECT_HASH", "").strip()
strict = os.environ.get("_E2E_DIAG_STRICT", "0").strip() == "1"
raw = os.environ.get("_E2E_DIAG_RAW", "")
attempts = int(os.environ.get("_E2E_DIAG_ATTEMPTS", "0"))
interval = int(os.environ.get("_E2E_DIAG_INTERVAL", "0"))

out = {
    "e2e_suite": suite,
    "failure": "poll_timeout",
    "agent_type": at,
    "agent_instance_id": aid,
    "expected_session_keys": keys,
    "poll_config": {"attempts": attempts, "interval_seconds": interval},
    "had_successful_cli_fetch": bool(raw),
}

m, err = behavioral_from_cli_output(raw)
if err:
    out["parse_error"] = err
    print(json.dumps(out, indent=2, ensure_ascii=False))
    raise SystemExit(0)
if m is None:
    out["parse_error"] = "no_model"
    print(json.dumps(out, indent=2, ensure_ascii=False))
    raise SystemExit(0)

if m == {"model": None} or (len(m) == 1 and m.get("model") is None):
    out["model_empty"] = True
    print(json.dumps(out, indent=2, ensure_ascii=False))
    raise SystemExit(0)

contribs = m.get("contributors") if isinstance(m.get("contributors"), list) else []
out["contributor_count"] = len(contribs)
out["contributor_keys"] = [
    {"agent_type": c.get("agent_type"), "agent_instance_id": c.get("agent_instance_id"), "hash_prefix": str(c.get("hash") or "")[:24]}
    for c in contribs[:24]
    if isinstance(c, dict)
]

found = None
for c in contribs:
    if c.get("agent_type") == at and c.get("agent_instance_id") == aid:
        found = c
        break
if not found and m.get("agent_type") == at and m.get("agent_instance_id") == aid:
    found = m
out["contributor_row_matched"] = bool(found)
if found:
    h = (found.get("hash") or "").strip()
    out["matched_contributor_hash_prefix"] = h[:32]
    out["strict_hash_check"] = {"enabled": strict, "expect_prefix": expect[:32], "match": (not strict or not expect or h == expect)}

preds = m.get("predictions") if isinstance(m.get("predictions"), list) else []
out["predictions_total"] = len(preds)
ours = [p for p in preds if isinstance(p, dict) and p.get("agent_type") == at and p.get("agent_instance_id") == aid]
out["predictions_for_agent"] = len(ours)
sk_have = []
for p in ours:
    sk = p.get("session_key")
    if sk and sk not in sk_have:
        sk_have.append(sk)
out["session_keys_present_for_agent"] = sk_have[:40]
missing = [sk for sk in keys if sk not in sk_have]
out["session_keys_missing"] = missing
oc_e2e_present = [x for x in sk_have if isinstance(x, str) and x.startswith("oc_e2e_")]
out["oc_e2e_keys_present"] = oc_e2e_present[:20]
out["hint"] = (
    "If session_keys_missing is non-empty but other agents have many predictions, merged model may have pruned this slice; "
    "try E2E_POLL_ATTEMPTS or inspect core merge limits."
)
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
)"
if [[ -n "${E2E_DIAGNOSTICS_FILE:-}" ]]; then
  printf '%s\n' "$DIAG_OUT" >"$E2E_DIAGNOSTICS_FILE"
  echo "Wrote diagnosis: $E2E_DIAGNOSTICS_FILE" >&2
else
  printf '%s\n' "$DIAG_OUT" >&2
fi
unset _E2E_DIAG_RAW _E2E_DIAG_SUITE _E2E_DIAG_AGENT_TYPE _E2E_DIAG_AGENT_ID _E2E_DIAG_SESSION_KEYS _E2E_DIAG_EXPECT_HASH _E2E_DIAG_STRICT _E2E_DIAG_ATTEMPTS _E2E_DIAG_INTERVAL

exit 1
