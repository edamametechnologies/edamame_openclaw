# EDAMAME for OpenClaw

**Runtime behavioral monitoring for [OpenClaw](https://openclaw.ai) agents,
powered by [EDAMAME Security](https://edamame.tech).**

## How It Works

1. The `edamame-extrapolator` skill reads agent session history and publishes
   behavioral models to EDAMAME via MCP.
2. EDAMAME's internal divergence engine correlates intent predictions against
   live system telemetry.
3. Verdicts (`CLEAN`, `DIVERGENCE`, `NO_MODEL`, `STALE`) are available through
   `get_divergence_verdict`.
4. The `edamame-posture` skill exposes posture, remediation, and telemetry
   endpoints as an on-demand MCP facade.

## Extrapolator Modes

The extrapolator supports two execution modes, selectable via the
`EXTRAPOLATOR_MODE` environment variable at provisioning time:

| Mode | LLM Tokens | Cron Cadence | How It Works |
|------|------------|--------------|--------------|
| `compiled` (default) | Zero OpenClaw LLM | Every 1 min | The `extrapolator_run_cycle` plugin tool deterministically extracts behavioral signals from session transcripts and forwards them to EDAMAME's internal LLM via `upsert_behavioral_model_from_raw_sessions`. |
| `llm` | Full agent runbook | Every 5 min | The OpenClaw agent LLM reads transcripts, reasons about expected system behavior, and builds the behavioral model payload directly via `upsert_behavioral_model`. |

Compiled mode is preferred for production: it eliminates per-cycle OpenClaw LLM
costs while producing equivalent behavioral models. The LLM-driven mode remains
available as a fallback when the EDAMAME plugin is unavailable or for
environments that benefit from richer agent reasoning.

```bash
EXTRAPOLATOR_MODE=compiled ./setup/provision.sh   # Default: zero LLM tokens
EXTRAPOLATOR_MODE=llm ./setup/provision.sh        # Full agent LLM reasoning
```

## Components

### MCP Plugin (`extensions/edamame/`)

An OpenClaw plugin exposing EDAMAME MCP tools to agents: telemetry,
posture, remediation, divergence, LAN scanning, breach detection, and more.

Key tools added in v2.0:
- `extrapolator_run_cycle` -- compiled extrapolation cycle (zero OpenClaw LLM)
- `upsert_behavioral_model_from_raw_sessions` -- forward raw transcripts to
  EDAMAME's internal LLM

### Scope Filters (Cross-Platform)

The MCP plugin tells the EDAMAME divergence engine which sessions belong to
OpenClaw using `scope_any_lineage_paths`. A session is in scope when any
level of its process lineage (process, parent, or grandparent) matches:

| Platform | Filter pattern | Matches |
|---|---|---|
| macOS (Homebrew) | `*/openclaw-gateway` | Compiled gateway binary |
| macOS/Linux (npm) | `*/bin/openclaw` | npm global CLI entrypoint |
| Linux (systemd) | `*/bin/openclaw` | systemd-managed gateway |
| Windows (Sched Task) | `*/openclaw-gateway`, `*/bin/openclaw` | Gateway process |

`scope_any_lineage_paths` is used instead of a single level because the
gateway can appear as parent or grandparent depending on tool-chain depth.

### Skills (`skill/`)

| Skill | Purpose |
|-------|---------|
| `edamame-extrapolator` | Reads session transcripts, publishes behavioral models. Tries `extrapolator_run_cycle` (compiled) first, falls back to LLM runbook. |
| `edamame-posture` | Thin MCP facade over EDAMAME posture/remediation workflows |

See [skill/README.md](skill/README.md) for architecture and distribution details.

## Quick Start

### EDAMAME app / posture CLI provisioning (recommended)

The easiest cross-platform install path. EDAMAME downloads the latest release
from GitHub (HTTP zipball -- no `git` required) and copies files using native
Rust file operations (no `bash` or `python` required):

```bash
# Via EDAMAME Posture CLI
edamame-posture install-agent-plugin openclaw

# Status check
edamame-posture agent-plugin-status openclaw
edamame-posture list-agent-plugins
```

The EDAMAME Security app also exposes an "Agent Plugins" section in AI
Settings with one-click install, status display, and intent injection test
buttons.

### Portable local install (bash)

```bash
bash setup/install.sh
```

This installs the MCP plugin, skills, and package metadata into `~/.openclaw/`
and optionally enables the plugin via `openclaw plugins enable edamame`.

### Portable local install (PowerShell, Windows)

```powershell
.\setup\install.ps1
```

PowerShell equivalent of `install.sh` for native Windows environments.

### Manual install

```bash
cp -r extensions/edamame ~/.openclaw/extensions/
openclaw plugins enable edamame
```

## Local E2E: OpenClaw-shaped raw ingest (no gateway)

To verify the same `RawReasoningSessionPayload` path the plugin uses for `upsert_behavioral_model_from_raw_sessions`,
without the OpenClaw CLI or gateway:

```bash
npm run e2e:inject
```

This builds three synthetic sessions via `scripts/e2e_build_openclaw_payload.mts` (reusing `_buildRawPayload`
from the plugin), calls `edamame_cli rpc upsert_behavioral_model_from_raw_sessions`, then polls
`get_behavioral_model` until `predictions[]` lists all three `session_key` values for `agent_type` `openclaw`.

Optional: `E2E_OPENCLAW_AGENT_INSTANCE_ID` forces the instance id used in the payload and verification
(reads `~/.edamame_openclaw_agent_instance_id` when unset, otherwise normalizes the hostname).

On poll timeout the script prints a JSON diagnosis (or writes it to `E2E_DIAGNOSTICS_FILE`): missing
`session_keys`, counts of predictions for your agent, contributor rows, and `oc_e2e_*` keys still present.
Use `E2E_PROGRESS_POLL=1` for per-poll stderr hints. Default `E2E_POLL_ATTEMPTS` is 36 (override for long soaks).

## Prerequisites

- [OpenClaw CLI](https://docs.openclaw.ai) installed
- [EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture)
  running with MCP enabled (the skills connect to `http://127.0.0.1:3000/mcp`)

### MCP Authentication

The MCP server supports two auth modes; both use the same credential file
(`~/.edamame_psk`) and both are sent as Bearer tokens:

- **App-mediated pairing** (developer workstations with the EDAMAME app): Run
  `./setup/pair.sh`, approve in the app. The credential is a per-client
  `edm_mcp_...` token.
- **Legacy shared PSK** (CLI/VM/daemon with `edamame_posture`): Generate with
  `edamame_posture background-mcp-generate-psk`, write to `~/.edamame_psk`.
  `setup/provision.sh` handles this for Lima VMs.

The plugin reads the credential from:

1. `EDAMAME_MCP_PSK` environment variable (takes precedence), or
2. `~/.edamame_psk` file (single-line, the PSK or token string)

The file **must** be owner-read/write only:

```bash
chmod 600 ~/.edamame_psk
```

### Stable OpenClaw Identity

OpenClaw deployments must use one stable `agent_instance_id` so EDAMAME
merges behavioral contributors correctly. The setup scripts persist that ID in
`~/.edamame_openclaw_agent_instance_id` and reuse it for pairing, cron jobs,
and compiled extrapolator runs.

- `setup/pair.sh` resolves and stores the deployment ID before requesting
  app-mediated pairing.
- `setup/provision.sh` recreates the extrapolator cron with the persisted ID
  embedded in the cron payload.
- The `edamame` plugin reads the same file and ignores legacy cron values such
  as `openclaw-default` or `<host>-main` once a stable ID exists.

## Running in a Lima VM

An example Lima template is provided for running the full EDAMAME + OpenClaw
stack in an isolated VM.

### 1. Create and start the VM

```bash
limactl create --name=edamame-openclaw setup/lima-example-openclaw.yaml
limactl start edamame-openclaw
```

### 2. Copy files into the VM

```bash
VM=edamame-openclaw

limactl cp setup/provision.sh                          $VM:/tmp/provision.sh
limactl cp -r skill                                    $VM:/tmp/skill
limactl cp -r extensions                               $VM:/tmp/extensions
```

### 3. Provision

```bash
limactl shell $VM -- bash /tmp/provision.sh
```

The provisioner installs EDAMAME Posture, configures the LLM provider, installs
skills and the MCP plugin, starts the OpenClaw gateway, and verifies end-to-end
MCP connectivity.

### Environment variables

Set these before running `provision.sh` (or place them in `../secrets/*.env`):

| Variable | Purpose |
|----------|---------|
| `EXTRAPOLATOR_MODE` | `compiled` (default, zero LLM tokens) or `llm` (agent runbook) |
| `EDAMAME_LLM_API_KEY` | EDAMAME Portal LLM key (divergence engine) |
| `EDAMAME_LLM_PROVIDER` | `edamame` (default), `openai`, `claude`, `ollama` |
| `EDAMAME_TELEGRAM_BOT_TOKEN` | Telegram Bot API token for notifications |
| `EDAMAME_TELEGRAM_CHAT_ID` | Telegram chat ID for alerts |
| `EDAMAME_TELEGRAM_INTERACTIVE_ENABLED` | Enable interactive buttons (`true`/`1`) |
| `EDAMAME_TELEGRAM_ALLOWED_USER_IDS` | Comma-separated authorized Telegram user IDs |
| `EDAMAME_AGENTIC_SLACK_BOT_TOKEN` | Slack bot token |
| `EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL` | Slack channel for routine summaries |
| `EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL` | Slack channel for escalations |

See `setup/provision.sh` header for the full list.

### Port mapping (example template)

| Guest | Host | Service |
|-------|------|---------|
| 40152 | 40153 | EDAMAME gRPC |
| 18789 | 18790 | OpenClaw Dashboard |
| 3000 | 3002 | EDAMAME MCP |

Alternate ports avoid conflicts with the macOS EDAMAME app.

## Demo Scripts

The `demo/` directory contains user-space injector scripts that trigger detectable security events (divergence, token exfiltration, sandbox escape, blacklisted communication). See [demo/README.md](demo/README.md) for usage.

## Setup Scripts

| Script | Purpose |
|--------|---------|
| `setup/install.sh` | Portable local install -- bash (plugin + skills into `~/.openclaw/`) |
| `setup/install.ps1` | Portable local install -- PowerShell for Windows |
| `setup/provision.sh` | Full VM provisioning (EDAMAME + OpenClaw + skills + MCP) |
| `setup/pair.sh` | App-mediated pairing for developer workstations (EDAMAME app) |
| `setup/build_posture.sh` | Build `edamame_posture` natively inside a Lima VM |
| `setup/verify_toolchain.sh` | Verify required tools are installed in the VM |
| `setup/lima-example-openclaw.yaml` | Example Lima VM template |

## Related Repositories

| Repository | Purpose |
|------------|---------|
| [edamame_cursor](https://github.com/edamametechnologies/edamame_cursor) | EDAMAME integration for Cursor IDE |
| [edamame_claude_code](https://github.com/edamametechnologies/edamame_claude_code) | EDAMAME integration for Claude Code |
| [agent_security](https://github.com/edamametechnologies/agent_security) | Research paper: two-plane runtime security (arXiv preprint) |

### Sibling Agent Integrations

- **edamame_claude_code** (Claude Code): Easy install via Claude Code marketplace:
  ```shell
  /plugin marketplace add edamametechnologies/edamame_claude_code
  /plugin install edamame@edamame-security
  ```
- **edamame_cursor** (Cursor): See [edamame_cursor README](https://github.com/edamametechnologies/edamame_cursor) for Cursor Marketplace or manual install (pending marketplace publication).
| [edamame_security](https://github.com/edamametechnologies/edamame_security) | EDAMAME Security desktop/mobile app |
| [edamame_posture](https://github.com/edamametechnologies/edamame_posture) | EDAMAME Posture CLI for CI/CD and servers |
| [edamame_core_api](https://github.com/edamametechnologies/edamame_core_api) | EDAMAME Core public API documentation |
| [threatmodels](https://github.com/edamametechnologies/threatmodels) | Public security benchmarks, policies, and threat models |

## License

Apache License 2.0 -- see [LICENSE](LICENSE).
