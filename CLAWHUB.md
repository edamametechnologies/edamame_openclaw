# ClawHub Publishing -- Assessment

This document records what it would take to publish the EDAMAME skills on
[ClawHub](https://clawhub.ai/) and the limitations that led us to defer it.

## Current Distribution

Skills are distributed as part of the `edamame` OpenClaw plugin bundle.
Installation is a single `cp -r` plus `openclaw plugins enable`. Provisioning
scripts (`setup/provision.sh`) handle VM and CI environments automatically.

## What ClawHub Publishing Would Require

### Per-Skill Manifests

Each skill needs a `clawhub.json` manifest with:

```json
{
  "name": "edamame-posture",
  "version": "1.0.0",
  "description": "...",
  "category": "security",
  "author": "EDAMAME Technologies",
  "entry": "SKILL.md",
  "minOpenClawVersion": "0.8.0",
  "tags": ["security", "runtime", "edamame"],
  "requires": {
    "tools": ["get_score", "get_divergence_verdict", "..."],
    "bins": [],
    "external": ["edamame_posture"],
    "plugins": ["edamame"]
  },
  "install": [
    { "id": "brew", "kind": "brew", "formula": "edamametechnologies/tap/edamame-posture", "os": ["darwin"] },
    { "id": "shell-linux", "kind": "shell", "command": "curl ... | sh", "os": ["linux"] }
  ],
  "security": {
    "mcp_tools": ["..."],
    "external_endpoints": ["http://127.0.0.1:3000/mcp"],
    "credential_access": false,
    "network_egress": true
  }
}
```

### Tooling

- `clawhub` CLI: `npm i -g clawhub`
- Authentication: `clawhub login`
- Publish command: `clawhub publish skill/edamame-posture --slug edamame-posture --version 1.0.0`

### CI Integration

A publish step would need to:
1. Validate `clawhub.json` schema for each skill.
2. Check that the version has been bumped (ClawHub rejects duplicate versions).
3. Run `clawhub publish` for each skill.
4. Tag the release.

## Limitations

### Plugin Dependency

The `edamame-posture` skill depends on the `edamame` plugin for MCP tool
access. ClawHub installs skills individually, but a standalone skill without
the plugin is non-functional. The `requires.plugins: ["edamame"]` field
declares this, but the user still needs to install the plugin separately. The
plugin bundle approach avoids this split.

### External Binary Dependency

The skill requires either `edamame_posture` or the EDAMAME Security app
running locally with MCP enabled. ClawHub's `install` hooks can install
`edamame_posture` via Homebrew or a shell script, but they cannot:

- Start or configure the daemon.
- Set up MCP authentication (PSK generation or app-mediated pairing).
- Configure the LLM provider for the divergence engine.

The user still needs to run `provision.sh` or manual setup steps after
`clawhub install`.

### Extrapolation Lives in the Plugin

Reasoning-plane publication is the compiled `extrapolator_run_cycle` tool
implemented in the `edamame` plugin. A ClawHub-only install of the posture
skill (without the plugin) does not get this tool, so behavioral models would
have to come from EDAMAME's host-side transcript observer alone. A bundle
install keeps the two paths together.

### Version Coordination

Skill versions, plugin versions, and `edamame_posture` versions must stay
compatible. ClawHub publishes each skill independently with its own version.
A user might install `edamame-posture@2.0.0` with an older `edamame@1.0.0`
plugin that lacks newer MCP tools. The plugin bundle approach keeps
everything in lockstep.

### Security Audit Surface

ClawHub's `security` manifest is informational. It does not enforce that a
skill only calls the declared MCP tools or endpoints. The security guarantees
come from EDAMAME's MCP auth layer, not from ClawHub metadata.

## When ClawHub Would Make Sense

ClawHub publishing becomes worthwhile when:

1. **OpenClaw supports plugin+skill bundles** -- a single `clawhub install`
   that installs both the plugin and its skills.
2. **Post-install hooks** -- ClawHub supports running setup scripts after
   installation (daemon start, MCP auth, LLM config).
3. **Version constraints** -- ClawHub enforces cross-dependency version
   ranges (skill X requires plugin Y >= 2.0).
4. **Discovery matters** -- if the OpenClaw marketplace becomes a significant
   distribution channel for security tooling.

Until then, the plugin bundle + provisioning script approach gives a more
reliable and complete installation experience.
