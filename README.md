# EDAMAME for OpenClaw

**EDAMAME Security integration for OpenClaw agents: MCP plugin, skills, and Lima VM provisioning.**

This repository contains everything needed to add runtime behavioral monitoring
to OpenClaw agents using [EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture).

## Components

### MCP Plugin (`extensions/edamame-mcp/`)

An OpenClaw plugin that exposes 31 EDAMAME MCP tools to agents:
telemetry, posture, remediation, divergence, LAN scanning, breach detection, and more.

### Skills (`skill/`)

| Skill | Purpose |
|-------|---------|
| `edamame-extrapolator` | Reads session transcripts and publishes behavioral models via `upsert_behavioral_model` |
| `edamame-posture` | Thin MCP facade over EDAMAME posture/remediation workflows |

### Publishing (`publish.sh`)

Publish skills to ClawHub and build the plugin bundle:

```bash
./publish.sh                    # Publish skills + build plugin bundle
./publish.sh --skills-only      # Publish to ClawHub only
./publish.sh --plugin-only     # Build plugin bundle only (no ClawHub)
./publish.sh --dry-run         # Show what would be done
```

Prerequisites: `clawhub` CLI (`npm i -g clawhub`) and `clawhub login`.

### Lima VM Setup (`setup/`)

Provision scripts for running the full EDAMAME + OpenClaw stack in a Lima VM:

```bash
./setup/setup.sh          # Create and boot the Lima VM
./setup/provision.sh      # Install EDAMAME Posture, configure LLM, start MCP
./setup/start.sh          # Start the OpenClaw gateway
./setup/stop.sh           # Stop services
```

## Quick Start

### Prerequisites

- [Lima](https://lima-vm.io/) installed on macOS
- OpenClaw CLI installed
- Secrets in `../secrets/` (see `setup/provision.sh` header for env vars)

### Setup

```bash
# Create and provision the Lima VM
./setup/setup.sh

# Or provision an existing VM
limactl shell openclaw-security -- bash setup/provision.sh
```

### Configuration

The provision script reads credentials from environment variables or `../secrets/`:

| Variable | Source File | Purpose |
|----------|------------|---------|
| `EDAMAME_LLM_API_KEY` | `edamame-llm.env` | EDAMAME Portal LLM key |
| `TELEGRAM_BOT_TOKEN` | `telegram.env` | Telegram notifications |
| `TELEGRAM_CHAT_ID` | `telegram.env` | Telegram chat target |
| `TELEGRAM_INTERACTIVE_ENABLED` | `telegram.env` | Bidirectional Telegram mode |
| `TELEGRAM_ALLOWED_USER_IDS` | `telegram.env` | Authorized interactive users |
| `SLACK_BOT_TOKEN` | `slack.env` | Slack notifications |
| `SLACK_CHANNEL_ID` | `slack.env` | Slack channel target |

See `setup/provision.sh` header for the full list of supported environment variables.

## Related Repositories

| Repository | Purpose |
|------------|---------|
| [openclaw_security](https://github.com/edamametechnologies/openclaw_security) | Dev/test/demo/CI monorepo |
| [edamame_cursor](https://github.com/edamametechnologies/edamame_cursor) | Cursor developer workstation package |
| [agent_security](https://github.com/edamametechnologies/agent_security) | Research paper and publication artifacts |
| [edamame_posture](https://github.com/edamametechnologies/edamame_posture_cli) | EDAMAME Posture CLI |
| [edamame_core](https://github.com/edamametechnologies/edamame_core) | Core security engine |
