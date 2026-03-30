# Setup

## Install Paths

### EDAMAME app / posture CLI

Recommended for most users. EDAMAME downloads the latest release zip and installs the plugin and skills without requiring `git`, `bash`, or Python:

```bash
edamame-posture install-agent-plugin openclaw
edamame-posture agent-plugin-status openclaw
```

### Portable local install

```bash
bash setup/install.sh
```

Windows:

```powershell
.\setup\install.ps1
```

This copies the plugin, skills, and metadata into `~/.openclaw/` and attempts to enable the plugin with the OpenClaw CLI.

### Manual install

```bash
cp -r extensions/edamame ~/.openclaw/extensions/
openclaw plugins enable edamame
```

## Pairing and Authentication

OpenClaw can authenticate to the local EDAMAME MCP endpoint in two ways:

| Mode | Best for | How |
|---|---|---|
| App-mediated pairing | developer workstations | run `./setup/pair.sh` and approve the request in the EDAMAME app |
| Shared PSK | CLI, VM, daemon, and lab flows | generate or provide a PSK, start the MCP endpoint, and store it in the expected file |

Credential lookup order:

1. `EDAMAME_MCP_PSK`
2. `~/.openclaw/edamame-openclaw/state/edamame-mcp.psk`
3. `~/.edamame_psk`

## Stable Identity

The plugin stores the stable deployment identity in:

```bash
~/.edamame_openclaw_agent_instance_id
```

This ID is reused by pairing, cron jobs, provisioning, and compiled extrapolator runs so EDAMAME merges contributor slices correctly.

## Lima / VM Provisioning

Lima VM provisioning scripts have moved to the
[openclaw_security](https://github.com/edamametechnologies/openclaw_security)
repository (`setup/provision.sh`, `setup/setup.sh`, `setup/start.sh`).

## Health and Verification

- Unit/helper tests: `npm test`
- Intent-injection E2E: `bash tests/e2e_inject_intent.sh`
- OpenClaw-side enablement: `openclaw plugins list`
- EDAMAME-side status: `edamame-posture agent-plugin-status openclaw`
