#!/bin/bash
# start.sh - Start the Lima VM and all services
#
# Starts: Lima VM → EDAMAME Posture daemon + MCP server → OpenClaw gateway
# Verifies MCP health + OpenClaw-native tool connectivity
#
# Usage: ./setup/start.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${VM_NAME:-openclaw-security}"
STRICT_PROOF="${STRICT_PROOF:-false}"
# shellcheck disable=SC1090
source "$REPO_DIR/tests/lib/vm_exec.sh"

warn_or_fail() {
    local msg="$1"
    if [ "$STRICT_PROOF" = "true" ]; then
        echo "ERROR: $msg"
        exit 1
    fi
    echo "WARNING: $msg"
}

echo "============================================"
echo "  Starting OpenClaw Security PoC"
echo "============================================"
echo ""
echo "Strict proof mode: $STRICT_PROOF"
echo ""

# ── Start Lima VM ──────────────────────────────
echo "--- Starting Lima VM '$VM_NAME' ---"
# NOTE: `limactl list --json` outputs NDJSON (one JSON object per line), not a JSON array.
if ! limactl list --json 2>/dev/null | jq -e "select(.name == \"$VM_NAME\")" &>/dev/null; then
    echo "ERROR: VM '$VM_NAME' does not exist. Run ./setup/setup.sh first."
    exit 1
fi

STATUS=$(limactl list --json 2>/dev/null | jq -r "select(.name == \"$VM_NAME\") | .status" | sed -n '1p')
if [ "$STATUS" = "Running" ]; then
    echo "  VM is already running."
else
    echo "  Starting VM..."
    limactl start "$VM_NAME"
    echo "  VM started."
fi

# ── Sync OpenClaw skills ──────────────────────
# The VM is provisioned once, so local edits to `skill/*/SKILL.md` won't
# automatically propagate into `~/.openclaw/skills/`. Sync on every start so
# the demo/benchmark always exercises the latest skill prompts.
echo ""
echo "--- Syncing OpenClaw skills from repo ---"
if ! vm_exec_raw bash -l << START_SYNC_EOF
    set -euo pipefail
    STRICT_PROOF="$STRICT_PROOF"
    SKILLS_SRC="$REPO_DIR/skill"
    for SKILL_DIR in edamame-extrapolator edamame-posture; do
        if [ -f "\$SKILLS_SRC/\$SKILL_DIR/SKILL.md" ]; then
            mkdir -p "\$HOME/.openclaw/skills/\$SKILL_DIR"
            cp "\$SKILLS_SRC/\$SKILL_DIR/SKILL.md" "\$HOME/.openclaw/skills/\$SKILL_DIR/SKILL.md"
            if [ -f "\$SKILLS_SRC/\$SKILL_DIR/clawhub.json" ]; then
                cp "\$SKILLS_SRC/\$SKILL_DIR/clawhub.json" "\$HOME/.openclaw/skills/\$SKILL_DIR/clawhub.json"
            fi
        else
            echo "WARN: missing skill source: \$SKILLS_SRC/\$SKILL_DIR/SKILL.md" >&2
        fi
    done

    # Older OpenClaw cron sessions still resolve the extrapolator skill via
    # the legacy "edamame-cortex-extrapolator" path. Keep a compatibility
    # copy in place so those runs load the current V3 prompt even if
    # symlinks are pruned by later OpenClaw housekeeping. Update it
    # in place so a concurrently firing cron never observes the path missing.
    if [ -d "\$HOME/.openclaw/skills/edamame-extrapolator" ]; then
        if [ -L "\$HOME/.openclaw/skills/edamame-cortex-extrapolator" ] || [ -f "\$HOME/.openclaw/skills/edamame-cortex-extrapolator" ]; then
            rm -f "\$HOME/.openclaw/skills/edamame-cortex-extrapolator"
        fi
        mkdir -p "\$HOME/.openclaw/skills/edamame-cortex-extrapolator"
        cp "\$HOME/.openclaw/skills/edamame-extrapolator/SKILL.md" \
            "\$HOME/.openclaw/skills/edamame-cortex-extrapolator/SKILL.md"
        if [ -f "\$HOME/.openclaw/skills/edamame-extrapolator/clawhub.json" ]; then
            cp "\$HOME/.openclaw/skills/edamame-extrapolator/clawhub.json" \
                "\$HOME/.openclaw/skills/edamame-cortex-extrapolator/clawhub.json"
        fi
    fi

    # Best-effort: restart gateway so skill changes take effect immediately.
    export PATH="\$HOME/.npm-global/bin:\$PATH"
    # Sync OpenClaw extension that exposes EDAMAME MCP tools as native tools.
    EXT_SRC="$REPO_DIR/extensions/edamame-mcp"
    if [ -f "\$EXT_SRC/openclaw.plugin.json" ] && [ -f "\$EXT_SRC/index.ts" ]; then
        mkdir -p "\$HOME/.openclaw/extensions/edamame-mcp"
        cp "\$EXT_SRC/openclaw.plugin.json" "\$HOME/.openclaw/extensions/edamame-mcp/openclaw.plugin.json"
        cp "\$EXT_SRC/index.ts" "\$HOME/.openclaw/extensions/edamame-mcp/index.ts"
        if grep -q "active_only" "\$HOME/.openclaw/extensions/edamame-mcp/index.ts" && grep -q "since" "\$HOME/.openclaw/extensions/edamame-mcp/index.ts"; then
            echo "  Synced edamame-mcp extension (get_sessions wrapper filters enabled)."
        else
            echo "WARN: synced edamame-mcp extension but get_sessions wrapper filters were not detected." >&2
        fi
        # Optional: plugin may already be enabled
        openclaw plugins enable edamame-mcp 2>/dev/null || true
    fi

    # Reload gateway after extension sync so tool registration is up to date.
    if ss -tln 2>/dev/null | grep -q ':18789 '; then
        if timeout 45s openclaw gateway restart >/tmp/openclaw-gateway-restart.log 2>&1; then
            for _ in \$(seq 1 20); do
                if ss -tln 2>/dev/null | grep -q ':18789 '; then
                    break
                fi
                sleep 1
            done
            echo "  Gateway restarted to apply extension updates."
        else
            if ss -tln 2>/dev/null | grep -q ':18789 '; then
                echo "WARN: gateway restart timed out after extension sync; gateway still listening, continuing."
                cat /tmp/openclaw-gateway-restart.log 2>/dev/null || true
            elif [ "\$STRICT_PROOF" = "true" ]; then
                echo "ERROR: gateway restart failed after extension sync"
                # Optional: log file may not exist
                cat /tmp/openclaw-gateway-restart.log 2>/dev/null || true
                exit 1
            else
                echo "WARN: gateway restart failed after extension sync; continuing."
            fi
        fi
    fi
START_SYNC_EOF
then
    warn_or_fail "skill/extension sync failed"
fi

# ── Load secrets ──────────────────────────────
SECRETS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OPENCLAW_MODEL_PROVIDER="${OPENCLAW_MODEL_PROVIDER:-foundry}"
case "$OPENCLAW_MODEL_PROVIDER" in
    foundry|auto)
        SECRETS_CANDIDATES=(
            "$SECRETS_ROOT/secrets.env"
            "$SECRETS_ROOT/secrets/foundry.env"
            "$SECRETS_ROOT/secrets/openai.env"
        )
        ;;
    openai)
        SECRETS_CANDIDATES=(
            "$SECRETS_ROOT/secrets/openai.env"
            "$SECRETS_ROOT/secrets.env"
        )
        ;;
    *)
        warn_or_fail "OPENCLAW_MODEL_PROVIDER must be one of: foundry, openai, auto"
        SECRETS_CANDIDATES=(
            "$SECRETS_ROOT/secrets.env"
            "$SECRETS_ROOT/secrets/foundry.env"
            "$SECRETS_ROOT/secrets/openai.env"
        )
        ;;
esac
SECRETS_FILE=""
FIRST_EXISTING_SECRETS=""
OPENAI_FALLBACK_SECRETS=""
for candidate in "${SECRETS_CANDIDATES[@]}"; do
    if [ ! -f "$candidate" ]; then
        continue
    fi
    if [ -z "$FIRST_EXISTING_SECRETS" ]; then
        FIRST_EXISTING_SECRETS="$candidate"
    fi

    HAS_OPENAI=1
    if ! bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; [ -n \"\${OPENAI_API_KEY:-}\" ]"; then
        HAS_OPENAI=0
    fi
    HAS_FOUNDRY=1
    if ! bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; [ -n \"\${FOUNDRY_API_KEY:-}\" ] && [ -n \"\${FOUNDRY_OPENAI_ENDPOINT:-\${FOUNDRY_OPENCLAW:-}}\" ]"; then
        HAS_FOUNDRY=0
    fi

    case "$OPENCLAW_MODEL_PROVIDER" in
        openai)
            if [ "$HAS_OPENAI" -eq 1 ]; then
                SECRETS_FILE="$candidate"
                break
            fi
            ;;
        foundry)
            if [ "$HAS_FOUNDRY" -eq 1 ]; then
                SECRETS_FILE="$candidate"
                break
            fi
            ;;
        auto)
            if [ "$HAS_FOUNDRY" -eq 1 ]; then
                SECRETS_FILE="$candidate"
                break
            fi
            if [ "$HAS_OPENAI" -eq 1 ] && [ -z "$OPENAI_FALLBACK_SECRETS" ]; then
                OPENAI_FALLBACK_SECRETS="$candidate"
            fi
            ;;
    esac
done
if [ -z "$SECRETS_FILE" ] && [ "$OPENCLAW_MODEL_PROVIDER" = "auto" ] && [ -n "$OPENAI_FALLBACK_SECRETS" ]; then
    SECRETS_FILE="$OPENAI_FALLBACK_SECRETS"
fi
if [ -z "$SECRETS_FILE" ] && [ "$OPENCLAW_MODEL_PROVIDER" = "foundry" ]; then
    if [ -n "${FOUNDRY_API_KEY:-}" ] && [ -n "${FOUNDRY_OPENAI_ENDPOINT:-${FOUNDRY_OPENCLAW:-}}" ]; then
        echo "  Using Foundry credentials from environment."
    else
        if [ -n "$FIRST_EXISTING_SECRETS" ]; then
            echo "ERROR: $FIRST_EXISTING_SECRETS exists but is incompatible with OPENCLAW_MODEL_PROVIDER=foundry."
        else
            echo "ERROR: Foundry provider requires FOUNDRY_API_KEY and FOUNDRY_OPENAI_ENDPOINT (or FOUNDRY_OPENCLAW)."
        fi
        exit 1
    fi
elif [ -z "$SECRETS_FILE" ]; then
    if [ -n "$FIRST_EXISTING_SECRETS" ]; then
        warn_or_fail "$FIRST_EXISTING_SECRETS exists but is incompatible with OPENCLAW_MODEL_PROVIDER=$OPENCLAW_MODEL_PROVIDER."
    else
        warn_or_fail "No secrets file found (checked openai.env, secrets.env, foundry.env). Agentic features may not work."
    fi
fi

SELECTED_MODEL_PROVIDER="$OPENCLAW_MODEL_PROVIDER"
if [ -n "$SECRETS_FILE" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
    set -u
fi

normalize_foundry_endpoint() {
    local raw="${1:-}"
    local cleaned resource
    cleaned="${raw%%\?*}"
    cleaned="${cleaned%/}"
    if [ -z "$cleaned" ]; then
        echo ""
        return
    fi
    case "$cleaned" in
        https://*.services.ai.azure.com/*|http://*.services.ai.azure.com/*)
            resource="$(printf "%s" "$cleaned" | sed -E 's#https?://([^.]+)\.services\.ai\.azure\.com.*#\1#')"
            if [ -n "$resource" ]; then
                echo "https://${resource}.openai.azure.com/openai/v1"
            else
                echo "$cleaned"
            fi
            ;;
        https://*.openai.azure.com/openai/v1|http://*.openai.azure.com/openai/v1|https://*.cognitiveservices.azure.com/openai/v1|http://*.cognitiveservices.azure.com/openai/v1)
            echo "$cleaned"
            ;;
        https://*.openai.azure.com/openai/*|http://*.openai.azure.com/openai/*|https://*.cognitiveservices.azure.com/openai/*|http://*.cognitiveservices.azure.com/openai/*)
            echo "${cleaned%%/openai/*}/openai/v1"
            ;;
        https://*.openai.azure.com|http://*.openai.azure.com|https://*.cognitiveservices.azure.com|http://*.cognitiveservices.azure.com)
            echo "${cleaned}/openai/v1"
            ;;
        https://*|http://*)
            if printf "%s" "$cleaned" | grep -q "/openai/v1"; then
                echo "${cleaned%%/openai/v1*}/openai/v1"
            elif printf "%s" "$cleaned" | grep -q "/openai/"; then
                echo "${cleaned%%/openai/*}/openai/v1"
            else
                echo "${cleaned}/openai/v1"
            fi
            ;;
        *)
            echo "$cleaned"
            ;;
    esac
}

if [ -z "${FOUNDRY_OPENAI_ENDPOINT:-}" ] && [ -n "${FOUNDRY_OPENCLAW:-}" ]; then
    FOUNDRY_OPENAI_ENDPOINT="$(normalize_foundry_endpoint "$FOUNDRY_OPENCLAW")"
fi
if [ -n "${FOUNDRY_OPENAI_ENDPOINT:-}" ]; then
    FOUNDRY_OPENAI_ENDPOINT="$(normalize_foundry_endpoint "$FOUNDRY_OPENAI_ENDPOINT")"
fi

if [ "$OPENCLAW_MODEL_PROVIDER" = "auto" ]; then
    if [ -n "${FOUNDRY_API_KEY:-}" ] && [ -n "${FOUNDRY_OPENAI_ENDPOINT:-${FOUNDRY_OPENCLAW:-}}" ]; then
        SELECTED_MODEL_PROVIDER="foundry"
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
        SELECTED_MODEL_PROVIDER="openai"
    fi
fi

if [ "$SELECTED_MODEL_PROVIDER" = "foundry" ]; then
    FOUNDRY_ENDPOINT_RAW="${FOUNDRY_OPENAI_ENDPOINT:-${FOUNDRY_OPENCLAW:-}}"
    if [ -z "$FOUNDRY_ENDPOINT_RAW" ]; then
        echo "ERROR: Foundry provider requires FOUNDRY_OPENAI_ENDPOINT (or FOUNDRY_OPENCLAW)."
        exit 1
    else
        FOUNDRY_BASE_URL="${FOUNDRY_ENDPOINT_RAW%/}"
        case "$FOUNDRY_BASE_URL" in
            */openai/v1) ;;
            *) FOUNDRY_BASE_URL="${FOUNDRY_BASE_URL}/openai/v1" ;;
        esac

        case "$FOUNDRY_BASE_URL" in
            *".services.ai.azure.com/api/projects/"*)
                warn_or_fail "Foundry endpoint appears to be an Azure AI project endpoint ($FOUNDRY_BASE_URL). Use FOUNDRY_OPENAI_ENDPOINT=https://<resource>.openai.azure.com for OpenAI Responses compatibility."
                ;;
        esac

        FOUNDRY_PRIMARY_MODEL="${FOUNDRY_PRIMARY_MODEL:-${FOUNDRY_DEPLOYMENT:-gpt-5.1}}"
        FOUNDRY_CONTEXT_WINDOW="${FOUNDRY_CONTEXT_WINDOW:-32000}"
        FOUNDRY_MAX_TOKENS="${FOUNDRY_MAX_TOKENS:-4096}"
        FOUNDRY_PRIMARY_MODEL_CANDIDATES=("$FOUNDRY_PRIMARY_MODEL")
        if [ -n "${FOUNDRY_DEPLOYMENT:-}" ]; then
            FOUNDRY_PRIMARY_MODEL_CANDIDATES+=("$FOUNDRY_DEPLOYMENT")
        fi
        FOUNDRY_PRIMARY_MODEL_CANDIDATES+=("gpt-5.1-2" "gpt-5.1")
        FOUNDRY_PRIMARY_MODEL="$(
            FOUNDRY_BASE_URL="$FOUNDRY_BASE_URL" FOUNDRY_API_KEY="${FOUNDRY_API_KEY:-}" \
            FOUNDRY_PRIMARY_MODEL_CANDIDATES_RAW="$(printf '%s\n' "${FOUNDRY_PRIMARY_MODEL_CANDIDATES[@]}")" \
            python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

base = os.environ.get("FOUNDRY_BASE_URL", "").rstrip("/")
key = os.environ.get("FOUNDRY_API_KEY", "")
raw = os.environ.get("FOUNDRY_PRIMARY_MODEL_CANDIDATES_RAW", "")
candidates = []
for line in raw.splitlines():
    m = line.strip()
    if m and m not in candidates:
        candidates.append(m)

chosen = ""
if base and key:
    for model in candidates:
        payload = {"model": model, "input": "healthcheck", "max_output_tokens": 256}
        req = urllib.request.Request(
            f"{base}/responses",
            data=json.dumps(payload).encode("utf-8"),
            headers={"api-key": key, "content-type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                if 200 <= r.status < 300:
                    chosen = model
                    break
        except urllib.error.HTTPError as e:
            body = e.read(500).decode("utf-8", "ignore").lower()
            if e.code in (400, 404) and (
                "deployment" in body
                or "does not exist" in body
                or "invalid 'model'" in body
                or "deploymentnotfound" in body
            ):
                continue
        except Exception:
            continue

print(chosen or candidates[0] if candidates else "gpt-5.1")
PY
        )"
        echo "  Provider selection: foundry"
        echo "  Normalizing OpenClaw model endpoint to: $FOUNDRY_BASE_URL"
        echo "  Resolved Foundry deployment/model: $FOUNDRY_PRIMARY_MODEL"
        vm_exec_raw env EXPECTED_FOUNDRY_BASE_URL="$FOUNDRY_BASE_URL" EXPECTED_FOUNDRY_MODEL="$FOUNDRY_PRIMARY_MODEL" EXPECTED_FOUNDRY_API_KEY="${FOUNDRY_API_KEY:-}" EXPECTED_FOUNDRY_CONTEXT_WINDOW="${FOUNDRY_CONTEXT_WINDOW:-32000}" EXPECTED_FOUNDRY_MAX_TOKENS="${FOUNDRY_MAX_TOKENS:-4096}" bash -l << 'FOUNDRY_CONFIG_EOF'
            python3 - <<PY
import json, os

def safe_int(val, default):
    try:
        return int(val) if val else default
    except (TypeError, ValueError):
        return default

p = os.path.expanduser("~/.openclaw/openclaw.json")
if not os.path.exists(p):
    raise SystemExit(0)

cfg = json.load(open(p, "r", encoding="utf-8"))
providers = ((cfg.setdefault("models", {})).setdefault("providers", {}))
azure = providers.setdefault("azure-openai-responses", {})
azure["baseUrl"] = os.environ["EXPECTED_FOUNDRY_BASE_URL"]
azure["api"] = "openai-responses"
azure["authHeader"] = False
api_key = os.environ.get("EXPECTED_FOUNDRY_API_KEY", "").strip()
if api_key:
    azure["apiKey"] = api_key
    headers = azure.setdefault("headers", {})
    headers["api-key"] = api_key

context_window = safe_int(os.environ.get("EXPECTED_FOUNDRY_CONTEXT_WINDOW"), 32000)
max_tokens = safe_int(os.environ.get("EXPECTED_FOUNDRY_MAX_TOKENS"), 4096)

models = azure.setdefault("models", [])
target_model = os.environ["EXPECTED_FOUNDRY_MODEL"]
if not any(isinstance(m, dict) and m.get("id") == target_model for m in models):
    models.append({
        "id": target_model,
        "name": f"Azure OpenAI ({target_model})",
        "reasoning": False,
        "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": context_window,
        "maxTokens": max_tokens,
        "compat": {"supportsStore": False},
    })
else:
    for m in models:
        if isinstance(m, dict) and m.get("id") == target_model:
            m["contextWindow"] = context_window
            m["maxTokens"] = max_tokens
            break

defaults = ((cfg.setdefault("agents", {})).setdefault("defaults", {}))
defaults.setdefault("model", {})["primary"] = f"azure-openai-responses/{target_model}"
defaults.setdefault("models", {})[f"azure-openai-responses/{target_model}"] = {}
defaults.setdefault("memorySearch", {})["enabled"] = True

with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\\n")
PY
FOUNDRY_CONFIG_EOF
    fi
fi

if [ "$SELECTED_MODEL_PROVIDER" = "openai" ]; then
    OPENAI_PRIMARY_MODEL="${OPENAI_PRIMARY_MODEL:-gpt-5.1}"
    echo "  Provider selection: openai"
    echo "  Primary OpenAI model: $OPENAI_PRIMARY_MODEL"
    vm_exec_raw env EXPECTED_OPENAI_MODEL="$OPENAI_PRIMARY_MODEL" EXPECTED_OPENAI_API_KEY="${OPENAI_API_KEY:-}" bash -l << 'OPENAI_CONFIG_EOF'
        python3 - <<PY
import json, os
p = os.path.expanduser("~/.openclaw/openclaw.json")
if not os.path.exists(p):
    raise SystemExit(0)

cfg = json.load(open(p, "r", encoding="utf-8"))
defaults = ((cfg.setdefault("agents", {})).setdefault("defaults", {}))
model = os.environ["EXPECTED_OPENAI_MODEL"]
defaults.setdefault("model", {})["primary"] = f"openai/{model}"
defaults.setdefault("models", {})[f"openai/{model}"] = {}
defaults.setdefault("memorySearch", {})["enabled"] = True

api_key = os.environ.get("EXPECTED_OPENAI_API_KEY", "").strip()
if api_key:
    cfg.setdefault("env", {})["OPENAI_API_KEY"] = api_key

with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\\n")
PY
OPENAI_CONFIG_EOF
fi

# ── Load EDAMAME LLM credentials ──────────────
# The internal divergence engine reads EDAMAME_LLM_API_KEY from the environment.
# Refresh /etc/edamame_llm.env from host secrets so VM restarts pick up changes.
EDAMAME_LLM_PROVIDER="${EDAMAME_LLM_PROVIDER:-edamame}"
EDAMAME_LLM_API_KEY="${EDAMAME_LLM_API_KEY:-}"
EDAMAME_LLM_MODEL="${EDAMAME_LLM_MODEL:-}"
EDAMAME_LLM_BASE_URL="${EDAMAME_LLM_BASE_URL:-}"
EDAMAME_TELEGRAM_BOT_TOKEN="${EDAMAME_TELEGRAM_BOT_TOKEN:-}"
EDAMAME_TELEGRAM_CHAT_ID="${EDAMAME_TELEGRAM_CHAT_ID:-}"

if [ "$EDAMAME_LLM_PROVIDER" = "edamame" ] && [ -z "$EDAMAME_LLM_API_KEY" ]; then
    for candidate in "$SECRETS_ROOT/secrets/edamame-llm.env" "$SECRETS_ROOT/secrets.env"; do
        if [ -f "$candidate" ]; then
            _key=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${EDAMAME_LLM_API_KEY:-}\"")
            if [ -n "$_key" ]; then
                EDAMAME_LLM_API_KEY="$_key"
                echo "  Loaded EDAMAME LLM key from $candidate"
                break
            fi
        fi
    done
fi

if [ "$EDAMAME_LLM_PROVIDER" = "openai" ] && [ -z "$EDAMAME_LLM_API_KEY" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
    EDAMAME_LLM_API_KEY="$OPENAI_API_KEY"
fi

if [ "$EDAMAME_LLM_PROVIDER" = "claude" ] && [ -z "$EDAMAME_LLM_API_KEY" ]; then
    for candidate in "$SECRETS_ROOT/secrets/claude.env"; do
        if [ -f "$candidate" ]; then
            _key=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${ANTHROPIC_API_KEY:-\${CLAUDE_API_KEY:-}}\"")
            if [ -n "$_key" ]; then
                EDAMAME_LLM_API_KEY="$_key"
                break
            fi
        fi
    done
fi

echo "  EDAMAME LLM provider: $EDAMAME_LLM_PROVIDER"

# Refresh the LLM env file inside the VM
vm_exec_raw env \
    _LLM_KEY="$EDAMAME_LLM_API_KEY" \
    _LLM_MODEL="$EDAMAME_LLM_MODEL" \
    _LLM_BASE_URL="$EDAMAME_LLM_BASE_URL" \
    _TELEGRAM_BOT_TOKEN="$EDAMAME_TELEGRAM_BOT_TOKEN" \
    _TELEGRAM_CHAT_ID="$EDAMAME_TELEGRAM_CHAT_ID" \
    bash -l << 'LLM_ENV_EOF'
    {
        echo "# EDAMAME internal LLM configuration (written by start.sh)"
        echo "EDAMAME_LLM_API_KEY=\"$_LLM_KEY\""
        echo "EDAMAME_LLM_MODEL=\"$_LLM_MODEL\""
        echo "EDAMAME_LLM_BASE_URL=\"$_LLM_BASE_URL\""
        echo "EDAMAME_TELEGRAM_BOT_TOKEN=\"$_TELEGRAM_BOT_TOKEN\""
        echo "EDAMAME_TELEGRAM_CHAT_ID=\"$_TELEGRAM_CHAT_ID\""
    } | sudo tee /etc/edamame_llm.env >/dev/null
    sudo chmod 600 /etc/edamame_llm.env
    # Ensure systemd picks up the env file
    if command -v systemctl >/dev/null 2>&1 && sudo systemctl is-enabled edamame_posture >/dev/null 2>&1; then
        sudo mkdir -p /etc/systemd/system/edamame_posture.service.d
        {
            echo "[Service]"
            echo "EnvironmentFile=/etc/edamame_llm.env"
        } | sudo tee /etc/systemd/system/edamame_posture.service.d/llm.conf >/dev/null
        sudo systemctl daemon-reload
    fi
LLM_ENV_EOF

# ── Install custom binary (if provided) ──────
if [ -n "${EDAMAME_POSTURE_BINARY:-}" ]; then
    echo ""
    echo "--- Installing provided EDAMAME Posture binary ---"
    vm_exec_raw env _BIN="$EDAMAME_POSTURE_BINARY" bash -l << 'CUSTOM_BIN_EOF'
        if [ -f "$_BIN" ]; then
            # Install runtime shared library dependencies for the cross-compiled binary
            for pkg in libgtk-3-0 libpcap0.8 libayatana-appindicator3-1; do
                if ! dpkg -s "$pkg" >/dev/null 2>&1; then
                    sudo apt-get install -y "$pkg" >/dev/null 2>&1
                fi
            done
            # Stop daemon first to release the binary (avoids "Text file busy").
            if command -v systemctl >/dev/null 2>&1 && sudo systemctl is-active edamame_posture >/dev/null 2>&1; then
                sudo systemctl stop edamame_posture 2>/dev/null || true
                sleep 2
            fi
            sudo cp "$_BIN" /usr/local/bin/edamame_posture
            sudo chmod +x /usr/local/bin/edamame_posture
            if [ -f /usr/bin/edamame_posture ]; then
                sudo cp "$_BIN" /usr/bin/edamame_posture
                sudo chmod +x /usr/bin/edamame_posture
            fi
            echo "  Installed: $(edamame_posture --version 2>&1 || echo 'version unknown')"
        else
            echo "  WARNING: EDAMAME_POSTURE_BINARY not found at $_BIN"
        fi
CUSTOM_BIN_EOF
fi

# ── Start EDAMAME Posture ─────────────────────
echo ""
echo "--- Starting EDAMAME Posture ---"
vm_exec_raw env STRICT_PROOF="$STRICT_PROOF" bash -l << 'EDAMAME_POSTURE_EOF'
    # Optional: /etc/environment may not exist
    source /etc/environment 2>/dev/null || true

    # Prefer systemd (the MCP server only works correctly when started via
    # the systemd service; manual background-start-disconnected causes the
    # MCP async runtime to hang).
    if command -v systemctl >/dev/null 2>&1 && sudo systemctl is-enabled edamame_posture >/dev/null 2>&1; then
        if sudo systemctl is-active edamame_posture >/dev/null 2>&1; then
            echo "  Daemon running via systemd."
        else
            echo "  Starting daemon via systemd..."
            sudo systemctl start edamame_posture
            sleep 12
        fi
    else
        if ! pgrep -f "edamame_posture.*(foreground|background)-" >/dev/null 2>&1; then
            echo "  Starting daemon..."
            sudo edamame_posture background-start-disconnected \
                --network-scan \
                --packet-capture 2>&1
            sleep 12
        else
            echo "  Daemon already running."
        fi
    fi

    # Wait for MCP to auto-start (up to 30s)
    echo "  Waiting for MCP server..."
    for _i in $(seq 1 15); do
        if sudo ss -tlnp 2>/dev/null | grep -q ":3000 "; then
            break
        fi
        sleep 2
    done

    if ! sudo ss -tlnp 2>/dev/null | grep -q ":3000 "; then
        echo "  MCP did not auto-start; attempting manual start..."
        PSK=$(openssl rand -base64 32 | tr -d "\n")
        sudo edamame_posture background-mcp-start 3000 "$PSK" 2>&1
        sleep 3
    fi

    # Recover PSK: read from daemon internal config, then sync to user file
    PSK=""
    if sudo test -f /root/.edamame/mcp_server_config.json; then
        PSK=$(sudo python3 -c "import json; print(json.load(open(\"/root/.edamame/mcp_server_config.json\")).get(\"psk\",\"\"))" 2>/dev/null)
    fi
    if [ -n "$PSK" ]; then
        printf "%s" "$PSK" > "$HOME/.edamame_psk"
        chmod 600 "$HOME/.edamame_psk"
        echo "  MCP PSK synced from daemon config."
    else
        if [ "$STRICT_PROOF" = "true" ]; then
            echo "  ERROR: could not recover MCP PSK from daemon config."
            exit 1
        fi
        echo "  WARNING: could not recover MCP PSK from daemon config."
    fi

    # Verify eBPF is active (critical for L7 process attribution accuracy)
    echo "  eBPF status:"
    if command -v journalctl >/dev/null 2>&1; then
        if sudo journalctl -u edamame_posture --no-pager -n 400 2>/dev/null \
            | grep -Eiq "eBPF.*initiali|flodbadd::capture"; then
            EBPF_MSG=$(sudo journalctl -u edamame_posture --no-pager -n 400 2>/dev/null \
                | grep -Ei "eBPF.*initiali|flodbadd::capture" | tail -1)
            echo "  eBPF/L7 capture ACTIVE: $EBPF_MSG"
        else
            if [ "$STRICT_PROOF" = "true" ]; then
                echo "  ERROR: no eBPF/L7 capture activation signal found in daemon logs"
                exit 1
            fi
            echo "  WARNING: no eBPF/L7 capture activation signal found in daemon logs"
        fi
    else
        echo "  (journalctl not available; cannot verify eBPF status)"
    fi

    # Packet capture probe (optional: generates traffic for session detection)
    curl -sS -m 8 --resolve one.one.one.one:443:1.0.0.1 https://one.one.one.one/ >/dev/null 2>&1 || true
    _capture_ok=""
    for _ in $(seq 1 10); do
        PSK_FILE="$HOME/.edamame_psk"
        # Optional: PSK file may not exist yet
        PSK="$(cat "$PSK_FILE" 2>/dev/null || true)"
        if [ -z "$PSK" ]; then
            break
        fi
        MCP_ACCEPT="Accept: application/json, text/event-stream"
        INIT_RESP=$(curl -sS -i -m 15 http://127.0.0.1:3000/mcp \
            -H "Content-Type: application/json" \
            -H "$MCP_ACCEPT" \
            -H "Authorization: Bearer $PSK" \
            -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"start\",\"version\":\"1.0\"}}}" 2>/dev/null || true)
        SID=$(echo "$INIT_RESP" | tr -d "\r" | awk -F": " "tolower(\$1)==\"mcp-session-id\" {print \$2; exit}")
        if [ -z "$SID" ]; then
            sleep 1
            continue
        fi
        curl -sS -m 15 http://127.0.0.1:3000/mcp \
            -H "Content-Type: application/json" \
            -H "$MCP_ACCEPT" \
            -H "Authorization: Bearer $PSK" \
            -H "Mcp-Session-Id: $SID" \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" > /dev/null 2>&1 || true
        RESP=$(curl -sS -m 30 http://127.0.0.1:3000/mcp \
            -H "Content-Type: application/json" \
            -H "$MCP_ACCEPT" \
            -H "Authorization: Bearer $PSK" \
            -H "Mcp-Session-Id: $SID" \
            -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_sessions\",\"arguments\":{}}}" 2>/dev/null || true)
        if echo "$RESP" | grep -q "\"result\""; then
            _capture_ok="yes"; break
        fi
        sleep 1
    done
    if [ "$_capture_ok" != "yes" ]; then
        if [ "$STRICT_PROOF" = "true" ]; then
            echo "  ERROR: packet capture probe did not detect sessions."
            exit 1
        fi
        echo "  WARNING: packet capture probe did not detect sessions."
    fi

    echo ""
    echo "  Daemon status:"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active edamame_posture 2>/dev/null | sed -n "1,1p" | sed "s/^/  - systemd: /"
    else
        ps aux | grep "[e]damame_posture" | head -1 | sed "s/^/  - process: /"
    fi
    echo "  MCP status:"
    if sudo ss -tlnp 2>/dev/null | grep -q ":3000 "; then
        echo "  - TCP bind: OK (:3000)"
        curl -s -m 2 http://127.0.0.1:3000/health 2>/dev/null | sed -n "1,1p" | sed "s/^/  - HTTP \\/health: /"
    else
        if [ "$STRICT_PROOF" = "true" ]; then
            echo "  ERROR: MCP TCP bind is closed (:3000)"
            exit 1
        fi
        echo "  - TCP bind: CLOSED (:3000)"
    fi
EDAMAME_POSTURE_EOF

# ── Start OpenClaw ────────────────────────────
echo ""
echo "--- Starting OpenClaw ---"
vm_exec_raw env STRICT_PROOF="$STRICT_PROOF" bash -l << 'OPENCLAW_START_EOF'
    # Optional: /etc/environment may not exist
    source /etc/environment 2>/dev/null || true
    export PATH="$HOME/.npm-global/bin:$PATH"

    if ! ss -tln 2>/dev/null | grep -q ":18789 "; then
        echo "  Starting gateway..."
        nohup openclaw gateway run --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
        for _ in $(seq 1 20); do
            if ss -tln 2>/dev/null | grep -q ":18789 "; then
                break
            fi
            sleep 1
        done
    else
        echo "  Gateway already running."
    fi

    openclaw status 2>/dev/null | head -15 || echo "  OpenClaw starting..."

    if [ "$STRICT_PROOF" = "true" ]; then
        MODEL_CONNECTIVITY=$(python3 - <<PY
import json, os
from urllib.parse import urlparse

p=os.path.expanduser("~/.openclaw/openclaw.json")
provider=""
target=""
try:
    cfg=json.load(open(p,"r",encoding="utf-8"))
except Exception:
    print("")
    print("")
    raise SystemExit(0)

primary=((cfg.get("agents",{}) or {}).get("defaults",{}) or {}).get("model",{}).get("primary","")
if isinstance(primary, str) and "/" in primary:
    provider=primary.split("/",1)[0]

if provider == "openai":
    target="https://api.openai.com"
elif provider == "azure-openai-responses":
    models = (cfg.get("models", {}) or {}).get("providers", {}) or {}
    base_url = ((models.get("azure-openai-responses") or {}).get("baseUrl") or "").strip()
    if base_url:
        parsed = urlparse(base_url)
        if parsed.scheme and parsed.netloc:
            target = f"{parsed.scheme}://{parsed.netloc}"

print(provider)
print(target)
PY
)
        MODEL_PROVIDER=$(echo "$MODEL_CONNECTIVITY" | sed -n "1p")
        MODEL_ENDPOINT=$(echo "$MODEL_CONNECTIVITY" | sed -n "2p")
        if [ -n "$MODEL_ENDPOINT" ]; then
            _mc_ok=false
            for _mc_try in 1 2 3 4 5; do
                if curl -sS -m 20 "$MODEL_ENDPOINT" >/dev/null 2>&1; then
                    _mc_ok=true
                    break
                fi
                echo "  Connectivity attempt $_mc_try/5 failed for $MODEL_ENDPOINT, retrying in ${_mc_try}s..."
                sleep "$_mc_try"
            done
            if [ "$_mc_ok" = "false" ]; then
                echo "WARNING: model provider endpoint is unreachable from the VM ($MODEL_PROVIDER => $MODEL_ENDPOINT) after 5 attempts."
                echo "  Proceeding anyway -- the OpenClaw gateway may route LLM traffic differently."
            fi
        fi
    fi
OPENCLAW_START_EOF

# ── Verify MCP connectivity ──────────────────
echo ""
echo "--- Verifying EDAMAME MCP server health (HTTP) ---"
set +e
MCP_TEST=$(vm_exec_raw bash -l << 'MCP_TEST_EOF'
    # Verify port is open
    if sudo ss -tlnp 2>/dev/null | grep -q ":3000 "; then
        echo "MCP port 3000: open"
    else
        echo "MCP port 3000: closed"
    fi
    curl -s -m 2 http://127.0.0.1:3000/health 2>/dev/null | sed -n "1,1p" | sed "s/^/HTTP \\/health: /" || true
MCP_TEST_EOF
) 2>&1
MCP_TEST_CODE=$?
set -e
echo "  $MCP_TEST" | sed 's/^/  /'
if [ "$STRICT_PROOF" = "true" ]; then
    if [ "$MCP_TEST_CODE" -ne 0 ] || echo "$MCP_TEST" | grep -q "MCP port 3000: closed"; then
        echo "ERROR: MCP health verification failed in strict proof mode."
        exit 1
    fi
fi

# ── Verify OpenClaw-native EDAMAME MCP tools (plugin) ────────────────
echo ""
echo "--- Verifying EDAMAME MCP tools (OpenClaw plugin) ---"
set +e
TOOL_TEST=$(vm_exec_raw bash -l << 'TOOL_TEST_EOF'
    set -euo pipefail
    export PATH="$HOME/.npm-global/bin:$PATH"
    TOKEN=$(python3 - <<PY
import json, os
p=os.path.expanduser("~/.openclaw/openclaw.json")
cfg=json.load(open(p,"r",encoding="utf-8"))
print(cfg.get("gateway",{}).get("auth",{}).get("token",""))
PY
)
    if [ -z "$TOKEN" ]; then
        echo "SKIP: no gateway token"
        exit 0
    fi
    RESP=""
    # Gateway can bind its port before it is ready to serve tools (extensions
    # still loading). Retry until we get a valid JSON tool response.
    for _ in $(seq 1 30); do
        RESP=$(curl -sS -m 20 http://127.0.0.1:18789/tools/invoke \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"tool\":\"advisor_get_todos\",\"args\":{}}" 2>/dev/null || true)
        if [ -z "$(echo "$RESP" | tr -d " \t\r\n")" ]; then
            sleep 1
            continue
        fi

        if python3 - "$RESP" <<'PY'
import json, sys
raw = sys.argv[1]
try:
  obj = json.loads(raw)
except Exception:
  raise SystemExit(1)
if not obj.get("ok"):
  raise SystemExit(2)
text = (obj.get("result", {}) or {}).get("content", [{}])[0].get("text", "")
try:
  data = json.loads(text)
  assert isinstance(data, list)
except Exception:
  raise SystemExit(3)
raise SystemExit(0)
PY
        then
            echo "advisor_get_todos: OK"
            exit 0
        fi

        sleep 1
    done

    echo "SKIP: advisor_get_todos not ready (tools/invoke did not return a valid tool payload)"
    exit 0
TOOL_TEST_EOF
) 2>&1
TOOL_TEST_CODE=$?
set -e
echo "  $TOOL_TEST" | sed 's/^/  /'
if [ "$STRICT_PROOF" = "true" ]; then
    if ! echo "$TOOL_TEST" | grep -q "advisor_get_todos: OK"; then
        echo "ERROR: OpenClaw-native MCP tool verification failed in strict proof mode."
        exit 1
    fi
fi

echo ""
echo "============================================"
echo "  All Services Started"
echo "============================================"
echo ""
echo "  Enter VM:        limactl shell $VM_NAME"
echo ""
echo "  Two-Plane Monitoring (MCP):"
echo "    limactl shell $VM_NAME -- bash -c 'export PATH=\$HOME/.npm-global/bin:\$PATH; openclaw agent --local --agent main -m \"Run extrapolator then read divergence verdict for two-plane security monitoring\"'"
echo ""
echo "  Cron jobs (Extrapolator + Divergence Verdict Reader via openclaw cron):"
echo "    limactl shell $VM_NAME -- bash -lc 'openclaw cron list'"
echo "    limactl shell $VM_NAME -- bash -lc 'openclaw cron run <job-id>'"
echo "  Dashboard:       http://localhost:18789/"
echo "  Stop:            ./setup/stop.sh"
echo "  Test:            ./tests/test_poc.sh"
echo ""
