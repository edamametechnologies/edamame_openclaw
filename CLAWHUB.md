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
  "name": "edamame-extrapolator",
  "version": "1.0.0",
  "description": "...",
  "category": "security",
  "author": "EDAMAME Technologies",
  "entry": "SKILL.md",
  "minOpenClawVersion": "0.8.0",
  "tags": ["security", "runtime", "edamame"],
  "requires": {
    "tools": ["upsert_behavioral_model", "sessions_list", "..."],
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
- Publish command: `clawhub publish skill/edamame-extrapolator --slug edamame-extrapolator --version 1.0.0`

### CI Integration

A publish step would need to:
1. Validate `clawhub.json` schema for each skill.
2. Check that the version has been bumped (ClawHub rejects duplicate versions).
3. Run `clawhub publish` for each skill.
4. Tag the release.

## Limitations

### Plugin Dependency

Both skills depend on the `edamame` plugin for MCP tool access. ClawHub
installs skills individually, but a standalone skill without the plugin is
non-functional. The `requires.plugins: ["edamame"]` field declares this,
but the user still needs to install the plugin separately. The plugin bundle
approach avoids this split.

### External Binary Dependency

Both skills require either `edamame_posture` or the EDAMAME Security app
running locally with MCP enabled. ClawHub's `install` hooks can install
`edamame_posture` via Homebrew or a shell script, but they cannot:

- Start or configure the daemon.
- Set up MCP authentication (PSK generation or app-mediated pairing).
- Configure the LLM provider for the divergence engine.

The user still needs to run `provision.sh` or manual setup steps after
`clawhub install`.

### Compiled Mode Requires Plugin

The preferred `compiled` extrapolator mode uses the `extrapolator_run_cycle`
tool, which is implemented in the `edamame` plugin. A ClawHub-only install
(skill without plugin) falls back to `llm` mode, consuming OpenClaw LLM tokens
on every cycle. This is a significant cost/performance difference that is not
obvious from the ClawHub listing.

### Version Coordination

Skill versions, plugin versions, and `edamame_posture` versions must stay
compatible. ClawHub publishes each skill independently with its own version.
A user might install `edamame-extrapolator@2.0.0` with an older
`edamame@1.0.0` plugin that lacks `extrapolator_run_cycle`. The plugin
bundle approach keeps everything in lockstep.

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
