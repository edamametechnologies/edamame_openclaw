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

- Compiled plugin-side `extrapolator_run_cycle` tool (zero OpenClaw LLM
  tokens) turns OpenClaw session history into behavioral models. EDAMAME's
  host-side transcript observer covers the same path automatically when
  OpenClaw is host-resident.
- EDAMAME internal ticker: divergence correlation and verdict lifecycle.
- OpenClaw `edamame-posture` skill: thin MCP facade (on-demand tool exposure).

```
Agent sessions                EDAMAME Posture daemon
     |                               |
     v                               v
+-------------------------+   +---------------------------+
| extrapolator_run_cycle  |   | Internal divergence       |
| (compiled plugin tool)  |   | engine (ticker)           |
| sessions -> behavioral  |   | correlate + safety floor  |
| model via               |   | + vulnerability detector  |
| upsert_behavioral_model |   | -> verdict state          |
| _from_raw_sessions      |   |                           |
+------------+------------+   +-------------+-------------+
             |                              |
             v                              v
     upsert_behavioral_model_        get_divergence_verdict
     from_raw_sessions                  (MCP read)
         (MCP write)

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
- `extrapolator_run_cycle` (compiled plugin tool): publishes behavioral expectations into EDAMAME from session transcripts.
- `edamame-posture` skill: reads and executes posture/telemetry/divergence/remediation actions through MCP.

Use them together, not as substitutes.

Reference: [`openclaw doctor` docs](https://docs.openclaw.ai/cli/doctor).

### When to use each

| Situation | Use `openclaw doctor` | Use EDAMAME |
|---|---|---|
| Gateway auth/config failures | Yes, first step | After doctor passes |
| MCP tool calls timing out or unauthorized | Yes, first step | Then rerun operations |
| Need behavioral model updates from sessions | Optional | Use `extrapolator_run_cycle` plugin tool |
| Need score/todos/remediation/divergence status | Optional | Use `edamame-posture` |
| Need to auto-repair OpenClaw local setup | Yes (`--repair` / `--fix`) | Not applicable |
| Need security posture decisions | No | Yes (`edamame-posture`) |

### Complementary flow

1. Run `openclaw doctor` (or `openclaw doctor --repair`) to establish healthy OpenClaw runtime.
2. Compiled `extrapolator_run_cycle` runs on schedule (or via EDAMAME's host-side observer) to maintain behavioral expectations in EDAMAME.
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

Provisioning installs the `edamame-posture` skill and the MCP plugin (which
ships the compiled `extrapolator_run_cycle` tool). Divergence and agentic
posture loops execute inside EDAMAME.
