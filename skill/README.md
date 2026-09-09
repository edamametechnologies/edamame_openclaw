# OpenClaw Security Skills

Runtime security skills for OpenClaw agents, powered by EDAMAME Posture telemetry.

## Distribution

Skills are distributed as a plugin bundle. The `edamame` plugin bundles the
on-demand posture skill alongside the MCP bridge:

```bash
cp -r extensions/edamame ~/.openclaw/extensions/
openclaw plugins enable edamame
```

## Architecture

Current model:

- EDAMAME's host-side transcript observer (inside `edamame_posture` or the
  EDAMAME app, running where OpenClaw runs) reads OpenClaw session history
  and builds the behavioral model. It is the only model producer; the plugin
  pushes nothing.
- EDAMAME internal ticker: divergence correlation and verdict lifecycle.
- OpenClaw `edamame-posture` skill: thin MCP facade (on-demand tool exposure).

```
Agent sessions (~/.openclaw/sessions)     EDAMAME Posture daemon
     |                                          |
     v                                          v
+---------------------------+   +---------------------------+
| Host-side transcript      |   | Internal divergence       |
| observer (system plane)   |-->| engine (ticker)           |
| transcripts -> behavioral |   | correlate + safety floor  |
| model                     |   | + attack pattern detector |
+---------------------------+   | -> verdict state          |
                                +-------------+-------------+
                                              |
                                              v
                                  get_divergence_verdict
                                  get_behavioral_model
                                      (MCP read)

+-----------------------------------------------------------+
| edamame-posture (on-demand skill)                         |
| Thin facade over EDAMAME MCP tools for score/todos,       |
| telemetry, divergence status, and remediation endpoints.  |
| No OpenClaw-side remediation loop; no security state in   |
| MEMORY.md.                                                |
+-----------------------------------------------------------+
```

## Skills vs `openclaw doctor`

`openclaw doctor` and EDAMAME tools solve different layers of the system:

- `openclaw doctor`: validates OpenClaw runtime health (gateway, config, channels, local readiness).
- EDAMAME host-side transcript observer: builds behavioral expectations from session transcripts (no OpenClaw-side action needed).
- `edamame-posture` skill: reads and executes posture/telemetry/divergence/remediation actions through MCP.

Use them together, not as substitutes.

Reference: [`openclaw doctor` docs](https://docs.openclaw.ai/cli/doctor).

### When to use each

| Situation | Use `openclaw doctor` | Use EDAMAME |
|---|---|---|
| Gateway auth/config failures | Yes, first step | After doctor passes |
| MCP tool calls timing out or unauthorized | Yes, first step | Then rerun operations |
| Need behavioral model updates from sessions | Optional | Automatic via EDAMAME's host-side observer |
| Need score/todos/remediation/divergence status | Optional | Use `edamame-posture` |
| Need to auto-repair OpenClaw local setup | Yes (`--repair` / `--fix`) | Not applicable |
| Need security posture decisions | No | Yes (`edamame-posture`) |

### Complementary flow

1. Run `openclaw doctor` (or `openclaw doctor --repair`) to establish healthy OpenClaw runtime.
2. EDAMAME's host-side observer maintains behavioral expectations from the transcripts on its own schedule.
3. Use `edamame-posture` on-demand for score, todos, telemetry, divergence reads, and explicit actions.
4. If tool transport/auth breaks again, return to step 1.

## Skills

### edamame-posture

Purpose:

- Expose EDAMAME Posture MCP tools directly to OpenClaw
- Provide a stable facade for posture, telemetry, divergence, and remediation APIs
- Keep security-critical state and loop logic inside EDAMAME

Key property:

- No OpenClaw-side periodic remediation loop
- No local file-based security state (`MEMORY.md` is not a source of truth for posture/divergence)

## Internal Divergence Engine (EDAMAME Core)

The divergence engine runs inside EDAMAME Core as a native background ticker.

MCP observability tools:

- `get_divergence_verdict`
- `get_divergence_history`
- `get_divergence_engine_status`

Loop lifecycle control is intentionally not exposed via MCP. Use
`edamame_posture divergence-start|divergence-stop` and
`edamame_posture agentic-start|agentic-stop`.

## Provisioning

```bash
./setup/provision.sh    # Local VM setup
./setup/pair.sh         # App-mediated pairing (developer workstations)
```

Provisioning installs the `edamame-posture` skill and the MCP plugin.
Behavioral modelling, divergence, and agentic posture loops all execute
inside EDAMAME.
