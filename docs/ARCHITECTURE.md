# Architecture

`edamame_openclaw` is the OpenClaw integration package in the EDAMAME agent-plugin family. It combines an OpenClaw MCP plugin, EDAMAME-facing skills, and provisioning scripts so OpenClaw reasoning activity can be correlated with EDAMAME system telemetry.

## Runtime Model

1. OpenClaw sessions are produced by the OpenClaw gateway and written to the local session store (`~/.openclaw/sessions/`).
2. EDAMAME's host-side transcript observer (inside `edamame_posture` or the EDAMAME app, running on the same host as OpenClaw) reads those transcripts and builds the behavioral model. It is the only model producer.
3. EDAMAME correlates the model with live network and host telemetry in its internal divergence engine.
4. This plugin connects to the local EDAMAME MCP endpoint over HTTP using a PSK or app-mediated credential and exposes read-only posture, telemetry, and divergence state to the agent, plus advisor workflows and `send_alert`.

> **Transcript observer.** Starting with `edamame_core` 1.2.3, EDAMAME runs its own host-side observer that probes `~/.openclaw/sessions/` and a few sibling locations. Operators can pause / resume / run-now per agent from the EDAMAME app's AI / Config tab. When the observer is paused while OpenClaw **is** discovered on disk, EDAMAME's `unsecured_openclaw` internal threat trips on the next score cycle (the threat keys on discovery, not plugin install). When OpenClaw is discovered but its transcripts are not reachable (`transcripts_root_accessible=false`), the AI tab shows "not observed on this host".

## Observer vs plugin: the value boundary

The security control of record is the **EDAMAME host-side observer**, and
it is the only path by which a behavioral model reaches EDAMAME. It is
observer-independent: it runs in the system plane, and a compromised
OpenClaw cannot pause, silence, or shape it. The MCP intake tools
(`upsert_behavioral_model`, `upsert_behavioral_model_from_raw_sessions`)
have been removed from EDAMAME's MCP surface and the compiled
`extrapolator_run_cycle` tool has been removed from this plugin, so the
reasoning plane can no longer declare a model about itself.

| | EDAMAME host-side observer | This package |
|---|---|---|
| Role | **Security control of record; sole behavioral-model producer** | Read-only tooling, advisor workflows, alerting, onboarding |
| Trust model | Observer-independent: system plane, cannot be silenced by a compromised agent | Consumer only: reads verdicts and telemetry; cannot add to or weaken a model or a verdict |
| Needs | OpenClaw transcripts readable on the host where EDAMAME runs | The OpenClaw gateway running this plugin and reaching an EDAMAME MCP endpoint |
| Provides the guarantee? | **Yes** | No; it surfaces the guarantee to the agent and the operator |

Because the observer reads the local filesystem, **it runs where the agent
runs**. For off-host OpenClaw (Lima VM, container, remote box, CI), install
`edamame_posture` in the guest / container / remote host and start it with
`background-start-disconnected`; divergence needs no Hub registration. See
the README's "Off-host OpenClaw" section.

Divergence adjudication, dismissals, and clearing state all stay
operator-only on the EDAMAME side (the MCP observer-independence policy).

## Core Components

| Path | Responsibility |
|---|---|
| `extensions/edamame/index.ts` | OpenClaw plugin entrypoint, tool registration, EDAMAME MCP client, response-trimming helpers |
| `skill/edamame-posture/SKILL.md` | Thin posture/remediation facade contract |
| `service/health.mjs` / `service/healthcheck_cli.mjs` | local health and operator checks |
| `setup/install.sh` / `setup/install.ps1` | per-user installation and plugin enablement |
| `setup/pair.sh` | app-mediated pairing for workstation installs |
| `tests/plugin.test.ts` | registered tool surface and MCP client error behaviour |
| `tests/plugin_helpers.test.ts` | helper-level contract coverage for session filtering and payload trimming |

## Tool Surface

The OpenClaw plugin exposes a broader EDAMAME surface than the workstation bridges. It includes:

- read-only telemetry and posture tools such as `get_sessions`, `get_score`, `get_behavioral_model`, `get_divergence_verdict`, and `advisor_get_todos`
- advisor workflow tools (`agentic_process_todos`, `agentic_get_workflow_status`, `agentic_execute_action`) and `add_pwned_email`
- `send_alert` for human escalation through OpenClaw messaging channels
- OpenClaw-specific helper logic for session filtering and payload trimming

It exposes no behavioral-model intake: the model is produced only by EDAMAME's host-side transcript observer. Operator-only mutators (undo, dismissals, LAN auto-scan, identity removal, clearing state) are not registered.

## Identity and Pairing

- The stable deployment identity used by pairing is stored in `~/.edamame_openclaw_agent_instance_id` (written by `setup/agent_identity.sh`; the plugin itself does not read it).
- Credentials are read from `EDAMAME_MCP_PSK`, `~/.openclaw/edamame-openclaw/state/edamame-mcp.psk`, or `~/.edamame_psk`.
- `setup/pair.sh` is the workstation pairing path.
- Lima VM provisioning has moved to [openclaw_security](https://github.com/edamametechnologies/openclaw_security).

## Design Constraints

- EDAMAME remains the source of truth for posture, telemetry, and divergence state.
- The OpenClaw plugin is intentionally broad, but it should keep pure helper logic split from tool registration so the plugin entrypoint stays reviewable and testable.
