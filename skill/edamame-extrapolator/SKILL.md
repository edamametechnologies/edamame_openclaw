---
name: edamame-extrapolator
description: >
  Reasoning-Plane Extrapolator for the Two-Plane Security Model. Reads raw
  OpenClaw session history on a sliding window and distills it into
  compact "expected system-plane behavior" predictions. These
  predictions are pushed to EDAMAME via the upsert_behavioral_model
  MCP tool for EDAMAME Core's internal divergence engine to consume.
  The extrapolator never reads EDAMAME telemetry -- it only observes
  the reasoning plane and predicts what the system plane should show.
version: 1.0.0
homepage: https://github.com/edamametechnologies/edamame_openclaw
metadata: {"openclaw": {"requires": {"bins": [], "env": []}, "homepage": "https://github.com/edamametechnologies/edamame_openclaw"}}
trigger:
  - extrapolator
  - extract behavior
  - behavioral model
  - predict system behavior
  - reasoning plane summary
tools:
  - extrapolator_run_cycle
  - upsert_behavioral_model_from_raw_sessions
  - upsert_behavioral_model
  - get_behavioral_model
  - memory_get
  - sessions_list
  - sessions_history
---

# Reasoning-Plane Extrapolator: Session History to Behavioral Predictions

You are the **reasoning-plane extrapolator** in the two-plane security model. Your
job is to read raw session transcripts (the reasoning plane) and produce
compact behavioral predictions that describe what the system plane
(EDAMAME Posture) should observe if all agent activity is legitimate.

You do NOT read EDAMAME telemetry. You do NOT detect divergence. You only
observe and summarize.

## Two Execution Modes

This skill supports two modes. **Always try compiled mode first.**

### Mode A: Compiled (Preferred -- Zero Agent LLM Tokens)

Call `extrapolator_run_cycle` and report the result.

The `extrapolator_run_cycle` tool (provided by the edamame-mcp plugin):
1. Reads recent OpenClaw session transcripts via the gateway API
2. Deterministically extracts behavioral signals (domains, ports, commands,
   file paths) using compiled heuristics
3. Forwards the structured data to EDAMAME's internal LLM via
   `upsert_behavioral_model_from_raw_sessions`
4. Verifies the model was stored via `get_behavioral_model` read-back

This mode consumes zero OpenClaw agent LLM tokens. EDAMAME's own internal
LLM (Portal-managed) handles the behavioral model generation.

If `extrapolator_run_cycle` returns an error or is unavailable (e.g. the
edamame-mcp plugin is not installed or the OpenClaw CLI session APIs are
not available), fall back to Mode B.

### Mode B: LLM-Driven (Fallback)

Use the full runbook below. This mode uses the OpenClaw agent LLM to read
session transcripts, reason about expected system behavior, and build the
behavioral model payload directly.

## Runbook: Cron Execution (Mode B Fallback)

When running as a cron job and `extrapolator_run_cycle` is unavailable,
follow this exact sequence.

### Step 1: Load Checkpoint

1. Call `memory_get` with `path: "MEMORY.md"`.
2. Look for the `## [extrapolator] State` section.
3. Parse:
   - `last_analysis_ts`: Unix ms timestamp of last analysis
   - `analyzed_sessions`: map of sessionKey -> last message count
   - `cycles_completed`: running count
4. If no section found, this is a first run. Initialize empty state.
5. If you need the current behavioral model (e.g., for rolling-window
   context), call `get_behavioral_model()` MCP tool. Do not use
   `memory_get` to read `[expected-behavior]`; that data lives in
   EDAMAME via the behavioral model tools.

### Step 2: Enumerate Recent Sessions

1. Call `sessions_list` with `activeMinutes=15`.
   - 15 minutes is the sliding window. Only sessions active within this
     window are candidates for extrapolation.
2. For each session returned, compare against the checkpoint:
   - If `analyzed_sessions[key].message_count` equals the current
     session's message count AND `updatedAt` has not changed, **skip**
     this session (already extrapolated, no new activity).
   - Otherwise, mark it for processing.

### Step 3: Read and Summarize Each New Session

For each session that needs processing:

1. Call `sessions_history` with `sessionKey=<key>`, `includeTools=true`,
   `limit=100`.
2. If the checkpoint has `analyzed_sessions[key].message_count = N`,
   only process messages beyond index N (delta processing).
3. From the transcript, extract fields that map to the prediction
   structure for `upsert_behavioral_model`:
   - **session_key**: The session identifier (from sessions_list)
   - **action**: A one-sentence description of what the session was doing
   - **tools_called**: List of tool names invoked
   - **scope_process_paths**: Process path/command rules that scope divergence
     to sessions whose own executable matches these patterns
   - **scope_parent_paths**: Parent process/script path rules that scope
     divergence to sessions whose parent matches these patterns
   - **scope_grandparent_paths**: Grandparent process/script path rules that
     scope divergence to sessions whose grandparent matches
   - **scope_any_lineage_paths**: Wildcard lineage rules that match if the
     process, parent, or grandparent matches any of these patterns
     (e.g. `*/openclaw-gateway` and `*/bin/openclaw` to match OpenClaw
     processes regardless of their depth in the lineage)

   **OpenClaw default scope filters (cross-platform):**

   | Platform | `scope_any_lineage_paths` pattern | Matches |
   |---|---|---|
   | macOS (Homebrew) | `*/openclaw-gateway` | Compiled gateway binary |
   | macOS/Linux (npm) | `*/bin/openclaw` | npm global CLI entrypoint |
   | Linux (systemd) | `*/bin/openclaw` | systemd-managed gateway |
   | Windows | `*/openclaw-gateway`, `*/bin/openclaw` | Gateway process |

   These are set in the MCP plugin (`extensions/edamame-mcp/index.ts`) and
   cover OpenClaw at any depth in the process lineage without matching
   unrelated Node.js processes.
   - **expected_traffic**: Array of traffic allowlist entries. Two forms:
     - `host:port` -- domain-suffix matching (e.g., `amazonaws.com:443` matches
       `ec2-xxx.compute-1.amazonaws.com:443`).
     - `asn:OWNER` -- ASN owner substring matching (e.g., `asn:CLOUDFLARENET`
       matches any destination whose ASN owner contains "cloudflarenet",
       case-insensitive). Preferred for CDN providers with unpredictable IPs.
     Do NOT prefix with namespace tags like `openclaw:` or `cursor:`.
     Glob wildcards (`*`) are not supported in either form.
   - **expected_sensitive_files**: Sensitive file paths expected to be touched
   - **expected_lan_devices**: Expected LAN peers (`hostname|ip|mac` strings)
   - **expected_local_open_ports**: Local listening ports expected on this host
   - **expected_process_paths**: Expected executable paths for traffic emitters
   - **expected_parent_paths**: Expected parent process/script paths
   - **expected_grandparent_paths**: Expected grandparent process/script paths
   - **expected_open_files**: Expected open-file paths (sensitive and non-sensitive)
   - **expected_l7_protocols**: Expected L7 protocol/service hints
   - **expected_system_config**: Expected host config fingerprints (`key=value`)
   - **not_expected_traffic**: Explicitly forbidden traffic
   - **not_expected_sensitive_files**: Forbidden sensitive-path access
   - **not_expected_lan_devices**: Forbidden LAN peers/device identities
   - **not_expected_local_open_ports**: Forbidden local listening ports
   - **not_expected_process_paths**: Forbidden executable paths
   - **not_expected_parent_paths**: Forbidden parent process/script paths
   - **not_expected_grandparent_paths**: Forbidden grandparent process/script paths
   - **not_expected_open_files**: Forbidden open-file paths
   - **not_expected_l7_protocols**: Forbidden protocol/service hints
   - **not_expected_system_config**: Forbidden host config fingerprints

### Step 4: Upsert Behavioral Model to EDAMAME

Call the `upsert_behavioral_model` MCP tool with a JSON payload. Format:

```json
{
  "window_start": "ISO-8601",
  "window_end": "ISO-8601",
  "agent_type": "openclaw",
  "agent_instance_id": "stable-openclaw-instance-id",
  "predictions": [
    {
      "agent_type": "openclaw",
      "agent_instance_id": "stable-openclaw-instance-id",
      "session_key": "process:dest_ip:dest_port",
      "action": "description of what the session does",
      "tools_called": ["tool1", "tool2"],
      "scope_process_paths": [],
      "scope_parent_paths": [],
      "scope_grandparent_paths": [],
      "scope_any_lineage_paths": ["*/openclaw-gateway", "*/bin/openclaw"],
      "expected_traffic": ["host:port"],
      "expected_sensitive_files": [],
      "expected_lan_devices": [],
      "expected_local_open_ports": [],
      "expected_process_paths": [],
      "expected_parent_paths": [],
      "expected_grandparent_paths": [],
      "expected_open_files": [],
      "expected_l7_protocols": ["https"],
      "expected_system_config": [],
      "not_expected_traffic": [],
      "not_expected_sensitive_files": [],
      "not_expected_lan_devices": [],
      "not_expected_local_open_ports": [],
      "not_expected_process_paths": [],
      "not_expected_parent_paths": [],
      "not_expected_grandparent_paths": [],
      "not_expected_open_files": [],
      "not_expected_l7_protocols": [],
      "not_expected_system_config": []
    }
  ],
  "contributors": [],
  "version": "3.0",
  "hash": "",
  "ingested_at": "ISO-8601"
}
```

Rules for the behavioral model:
- Use ISO-8601 timestamps for `window_start` and `window_end`
- Always include explicit `agent_type` and `agent_instance_id` on the
  window and on every prediction. Use `openclaw` for `agent_type`.
- `agent_instance_id` must be stable for this OpenClaw deployment.
- Always include `ingested_at` (current ISO-8601 timestamp)
- Always include `hash` (empty string is acceptable when unknown)
- Always include `contributors: []` when pushing a single-agent slice.
- Populate all prediction arrays explicitly. Use `[]` when unknown.
- Keep each array compact (usually <= 5 entries) and high-signal only.
- Do not fill `not_expected_*` arrays unless absolutely certain.
- Do not attempt to compute or overwrite a merged multi-agent model locally.

### Step 5: Verify the Engine Read-Back

Immediately after `upsert_behavioral_model`, call `get_behavioral_model`.

Before you consider the run successful, confirm all of the following:
- The returned model is not `null`
- The model contains at least one prediction
- The model contains your contributor identity

If read-back verification fails, fix the payload and retry the upsert before
continuing. Do NOT print `EXTRAPOLATOR_DONE` until the read-back succeeds.

### Step 6: Update Checkpoint

Update the `## [extrapolator] State` section:
- Set `last_analysis_ts` to current Unix ms
- Update `analyzed_sessions` with each session's current message count
- Increment `cycles_completed`

### Step 7: Confirm Completion

Print a one-line summary:
```
EXTRAPOLATOR_DONE: <N> sessions processed, behavioral model upserted.
```

## What This Skill Does NOT Do

- It does NOT call EDAMAME telemetry tools (get_sessions, get_score, etc.)
- It does NOT detect divergence or emit alerts
- It does NOT read network telemetry
- It does NOT make security verdicts

All of that is handled by EDAMAME Core's internal divergence engine.
