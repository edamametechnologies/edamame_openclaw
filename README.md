# EDAMAME for OpenClaw

> **ARCHIVED (EDAMAME 1.7.0):** Level-2 agent plugin distribution is retired. Host-side transcript observation is the default monitoring path; prevention is via **nono** / **srt** governance harnesses. The remaining release gate is [edamame_posture fleet monitoring](https://github.com/edamametechnologies/edamame_posture_cli/blob/main/.github/workflows/agent_monitoring_e2e.yml).

**Runtime behavioral monitoring for [OpenClaw](https://openclaw.ai) agents,
powered by [EDAMAME Security](https://edamame.tech).**

## How It Works

1. EDAMAME's **host-side transcript observer** (inside the `edamame_posture`
   daemon or the EDAMAME app) reads OpenClaw session transcripts from
   `~/.openclaw/sessions/` on the host where OpenClaw runs and builds the
   behavioral model. It is the only behavioral-model producer; this plugin
   pushes nothing.
2. EDAMAME's internal divergence engine correlates the model against live
   system telemetry (network sessions, sensitive-file access, process
   lineage, LAN, breaches).
3. Verdicts (`CLEAN`, `DIVERGENCE`, `NO_MODEL`, `STALE`) are available
   read-only through `get_divergence_verdict` / `get_divergence_history`.
4. The `edamame-posture` skill exposes posture, remediation, and telemetry
   endpoints as an on-demand MCP facade over the plugin's read-only tools.

## Observer vs plugin: what provides the security

EDAMAME's **host-side transcript observer is the only path by which a
behavioral model reaches EDAMAME**. It is observer-independent: it runs in
the system plane, a compromised OpenClaw cannot pause, silence, or shape
it, and it needs no plugin. The MCP intake tools that used to let a plugin
push a model (`upsert_behavioral_model`,
`upsert_behavioral_model_from_raw_sessions`) have been removed from
EDAMAME's MCP surface, and the compiled `extrapolator_run_cycle` tool has
been removed from this plugin: a model declared by the reasoning plane
about itself is exactly what an attacker who controls the agent would
forge.

What this plugin still provides:

- **Read-only tooling** for the agent: posture score, todos, sessions,
  anomalous / blacklisted sessions, LAN devices, breaches, the current
  behavioral model, and divergence verdicts.
- **Advisor workflows** (`agentic_process_todos`, `agentic_execute_action`)
  that operate on advisor todos, never on observer findings.
- **Onboarding**: app-mediated pairing, PSK credential handling, and the
  `edamame-posture` skill facade.
- **`send_alert`** so a skill can page a human through the OpenClaw
  messaging channels.

Divergence adjudication, dismissals, and clearing state stay
operator-only on the EDAMAME side. See
[Observer vs plugin: the value boundary](docs/ARCHITECTURE.md#observer-vs-plugin-the-value-boundary).

## Off-host OpenClaw (Lima VM, container, remote)

**The observer runs where the agent runs.** The transcript observer reads
OpenClaw's session files from the local filesystem, so an EDAMAME instance
on the macOS host cannot observe an OpenClaw gateway running inside a
Lima VM, a Docker container, or on a remote box. In that case install
`edamame_posture` in the guest / container / remote host, next to
OpenClaw, and start it disconnected:

```bash
edamame_posture background-start-disconnected
```

Divergence needs no Hub registration: the observer, the divergence
engine, and the attack pattern detector all run locally in that daemon.
Point the plugin at that daemon's MCP endpoint (`EDAMAME_MCP_ENDPOINT`,
default `http://127.0.0.1:3000/mcp`) if the skill should read verdicts
from inside the guest.

When OpenClaw is discovered on a host but its transcripts are not
reachable there (`transcripts_root_accessible=false`), the EDAMAME app's
AI tab shows the agent as **"not observed on this host"** rather than as
absent. That is the cue to deploy `edamame_posture` where OpenClaw runs.

Lima VM provisioning has moved to
[openclaw_security](https://github.com/edamametechnologies/openclaw_security).

## Components

### MCP Plugin (`extensions/edamame/`)

An OpenClaw plugin exposing EDAMAME MCP tools to agents: telemetry,
posture, remediation, divergence, LAN scanning, breach detection, and more.

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

## Prerequisites

- [OpenClaw CLI](https://docs.openclaw.ai) installed
- [EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture)
  running with MCP enabled (the skills connect to `http://127.0.0.1:3000/mcp`)

### MCP Authentication

The MCP server supports two auth modes, both sent as Bearer tokens:

- **App-mediated pairing** (developer workstations with the EDAMAME app): Run
  `./setup/pair.sh`, approve in the app. The credential is a per-client
  `edm_mcp_...` token stored in
  `~/.openclaw/edamame-openclaw/state/edamame-mcp.psk`.
- **Shared PSK** (CLI/VM/daemon with `edamame_posture`): Generate and
  start the MCP endpoint, then write the PSK to `~/.edamame_psk`:

  ```bash
  edamame-posture mcp-generate-psk          # or: background-mcp-generate-psk
  edamame-posture mcp-start 3000 "<PSK>"    # or: background-mcp-start
  ```

  For Lima VMs, see [openclaw_security](https://github.com/edamametechnologies/openclaw_security) `setup/provision.sh`.

The plugin reads the credential in this order:

1. `EDAMAME_MCP_PSK` environment variable (takes precedence)
2. `~/.openclaw/edamame-openclaw/state/edamame-mcp.psk` (app-mediated pairing)
3. `~/.edamame_psk` (shared PSK / legacy)

Credential files **must** be owner-read/write only:

```bash
chmod 600 ~/.openclaw/edamame-openclaw/state/edamame-mcp.psk
chmod 600 ~/.edamame_psk
```

### Stable OpenClaw Identity

OpenClaw deployments use one stable `agent_instance_id` so EDAMAME merges
observer contributors and pairing state correctly. The setup scripts
persist that ID in `~/.edamame_openclaw_agent_instance_id`.

- `setup/pair.sh` resolves and stores the deployment ID before requesting
  app-mediated pairing.
- The plugin itself no longer reads this file: it pushes no model, so it
  has no instance identity to declare.

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

## E2E Tests

The per-repo intent-injection E2E has been removed with the plugin's
model-push path. The cross-agent E2E harness (observer-driven intent +
CVE/divergence scenarios) lives in
[edamame_posture/tests/e2e/](https://github.com/edamametechnologies/edamame_posture_cli/tree/main/tests/e2e).
Run triggers with `--agent-type openclaw`.

## Setup Scripts

| Script | Purpose |
|--------|---------|
| `setup/install.sh` | Portable local install -- bash (plugin + skills into `~/.openclaw/`) |
| `setup/install.ps1` | Portable local install -- PowerShell for Windows |
| `setup/provision.sh` | Full VM provisioning (EDAMAME + OpenClaw + skills + MCP) |
| `setup/pair.sh` | App-mediated pairing for developer workstations (EDAMAME app) |
| `setup/build_posture.sh` | Build `edamame_posture` natively inside a Lima VM |
| `setup/lima-example-openclaw.yaml` | Example Lima VM template |

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/SETUP.md](docs/SETUP.md)
- [docs/VALIDATION.md](docs/VALIDATION.md)

## Related Repositories

| Repository | Purpose |
|------------|---------|
| [edamame_cursor](https://github.com/edamametechnologies/edamame_cursor) | EDAMAME integration for Cursor IDE |
| [edamame_claude_code](https://github.com/edamametechnologies/edamame_claude_code) | EDAMAME integration for Claude Code |
| [edamame_claude_desktop](https://github.com/edamametechnologies/edamame_claude_desktop) | EDAMAME integration for Claude Desktop |
| [edamame_codex](https://github.com/edamametechnologies/edamame_codex) | EDAMAME integration for Codex CLI |
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
