# Architecture

`edamame_openclaw` is the OpenClaw integration package in the EDAMAME agent-plugin family. It combines an OpenClaw MCP plugin, EDAMAME-facing skills, and provisioning scripts so OpenClaw reasoning activity can be correlated with EDAMAME system telemetry.

## Runtime Model

1. OpenClaw sessions are produced by the OpenClaw gateway and local session store.
2. The compiled plugin-side `extrapolator_run_cycle` tool turns those sessions into a behavioral payload (zero OpenClaw LLM tokens). EDAMAME's host-side transcript observer follows the same path automatically when OpenClaw is host-resident.
3. The plugin forwards data to the local EDAMAME MCP endpoint over HTTP using a PSK or app-mediated credential.
4. EDAMAME stores the behavioral contributor, correlates it with live network and host telemetry, and returns read-only posture and divergence state through the plugin tools.

> **External transcript observer (additive, host-resident only).** Starting with `edamame_core` 1.2.3, EDAMAME runs its own host-side observer that probes `~/.openclaw/sessions/` and a few sibling locations for OpenClaw transcripts. OpenClaw normally runs in Lima or remote, so on most workstations the observer reports `transcripts_root_accessible=false` (i.e. OpenClaw is not **discovered** on the host) and produces no slices -- this is expected and not an error. This plugin's existing MCP path keeps working unchanged in that case; the observer is the security primitive whenever OpenClaw is host-resident. Operators can pause / resume / run-now per agent from the EDAMAME app's AI / Config tab. When the observer is paused while OpenClaw **is** discovered on disk, EDAMAME's `unsecured_openclaw` internal threat trips on the next score cycle (the threat keys on discovery, not plugin install).

## Core Components

| Path | Responsibility |
|---|---|
| `extensions/edamame/index.ts` | OpenClaw plugin entrypoint, tool registration, EDAMAME MCP client, payload helpers |
| `skill/edamame-posture/SKILL.md` | Thin posture/remediation facade contract |
| `service/health.mjs` / `service/healthcheck_cli.mjs` | local health and operator checks |
| `setup/install.sh` / `setup/install.ps1` | per-user installation and plugin enablement |
| `setup/pair.sh` | app-mediated pairing for workstation installs |
| `tests/plugin_helpers.test.ts` | helper-level contract coverage for payload trimming and identity logic |
| `tests/e2e_inject_intent.sh` | local raw-session intent injection E2E |

## Tool Surface

The OpenClaw plugin exposes a broader EDAMAME surface than the workstation bridges. It includes:

- read-only telemetry and posture tools such as `get_sessions`, `get_score`, `get_divergence_verdict`, and `advisor_get_todos`
- behavioral-model ingest tools such as `upsert_behavioral_model_from_raw_sessions`
- OpenClaw-specific helper logic for session filtering, payload trimming, transcript extraction, and stable `agent_instance_id` handling

## Extrapolation

Reasoning-plane publication uses the compiled `extrapolator_run_cycle` plugin
tool: deterministic plugin-side extraction, then EDAMAME-internal LLM
generation through `upsert_behavioral_model_from_raw_sessions`. This consumes
zero OpenClaw agent LLM tokens per cycle. EDAMAME's host-side transcript
observer covers the same path automatically when OpenClaw is host-resident.

## Identity and Pairing

- The stable deployment identity is stored in `~/.edamame_openclaw_agent_instance_id`.
- Credentials are read from `EDAMAME_MCP_PSK`, `~/.openclaw/edamame-openclaw/state/edamame-mcp.psk`, or `~/.edamame_psk`.
- `setup/pair.sh` is the workstation pairing path.
- Lima VM provisioning has moved to [openclaw_security](https://github.com/edamametechnologies/openclaw_security).

## Design Constraints

- EDAMAME remains the source of truth for posture, telemetry, and divergence state.
- The OpenClaw plugin is intentionally broad, but it should keep pure helper logic split from tool registration so the plugin entrypoint stays reviewable and testable.
