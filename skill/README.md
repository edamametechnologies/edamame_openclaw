# OpenClaw Security Skills

Runtime security skills for OpenClaw agents, powered by EDAMAME Posture telemetry.

## Distribution

Skills are distributed through two channels.

### ClawHub (individual skills)

Each skill is published independently to [ClawHub](https://clawhub.ai/):

```bash
clawhub install edamame-extrapolator
clawhub install edamame-posture
```

Skills that require EDAMAME Posture declare `requires.bins: ["edamame_posture"]`
in metadata. OpenClaw only enables these skills when `edamame_posture` is on
`PATH`.

### Plugin bundle (all-in-one)

The `edamame-mcp` plugin bundles both skills alongside the MCP bridge:

```bash
cp -r extensions/edamame-mcp ~/.openclaw/extensions/
openclaw plugins enable edamame-mcp
```

## Architecture

Current model:

- OpenClaw cron: `edamame-extrapolator` (session history -> behavioral model)
- EDAMAME internal ticker: divergence correlation and verdict lifecycle
- OpenClaw `edamame-posture` skill: thin MCP facade (on-demand tool exposure)

```
Agent sessions                EDAMAME Posture daemon
     |                               |
     v                               v
+-------------------------+   +---------------------------+
| extrapolator            |   | Internal divergence       |
| (cron: every 2-5 min)   |   | engine (ticker)           |
| sessions_list/history   |   | correlate + safety floor  |
| -> upsert_behavioral_   |   | + vulnerability detector  |
| model                   |   | -> verdict state          |
+------------+------------+   +-------------+-------------+
             |                              |
             v                              v
     upsert_behavioral_model         get_divergence_verdict
         (MCP write)                    (MCP read)

+-----------------------------------------------------------+
| edamame-posture (on-demand skill)                         |
| Thin facade over EDAMAME MCP tools for score/todos,       |
| telemetry, divergence status, and remediation endpoints.   |
| No OpenClaw-side remediation loop; no security state in    |
| MEMORY.md.                                                 |
+-----------------------------------------------------------+
```

## Skills vs `openclaw doctor`

`openclaw doctor` and EDAMAME skills solve different layers of the system:

- `openclaw doctor`: validates OpenClaw runtime health (gateway, config, channels, local readiness)
- `edamame-extrapolator`: writes behavioral expectations into EDAMAME
- `edamame-posture`: reads and executes posture/telemetry/divergence/remediation actions through MCP

Use them together, not as substitutes.

Reference: [`openclaw doctor` docs](https://docs.openclaw.ai/cli/doctor).

### When to use each

| Situation | Use `openclaw doctor` | Use EDAMAME skills |
|---|---|---|
| Gateway auth/config failures | Yes, first step | After doctor passes |
| MCP tool calls timing out or unauthorized | Yes, first step | Then rerun skill operations |
| Need behavioral model updates from sessions | Optional | Use `edamame-extrapolator` |
| Need score/todos/remediation/divergence status | Optional | Use `edamame-posture` |
| Need to auto-repair OpenClaw local setup | Yes (`--repair` / `--fix`) | Not applicable |
| Need security posture decisions | No | Yes (`edamame-posture`) |

### Complementary flow

1. Run `openclaw doctor` (or `openclaw doctor --repair`) to establish healthy OpenClaw runtime.
2. Run `edamame-extrapolator` on schedule to maintain behavioral expectations in EDAMAME.
3. Use `edamame-posture` on-demand for score, todos, telemetry, divergence reads, and explicit actions.
4. If tool transport/auth breaks again, return to step 1.

## Skills

### edamame-extrapolator

Purpose:

- Read OpenClaw session history (`sessions_list`, `sessions_history`)
- Distill behavioral predictions
- Emit V3 prediction fields (`expected_traffic`, `expected_sensitive_files`,
  extended `expected_*` dimensions, and per-dimension `not_expected_*` rules)
- Push model to EDAMAME with `upsert_behavioral_model`

Checkpoint behavior:

- Writes only operational cursor/checkpoint state under
  `## [extrapolator] State`

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

## Publishing

```bash
./publish.sh                    # Publish all skills + build plugin bundle
./publish.sh --skills-only      # Publish skills to ClawHub only
./publish.sh --plugin-only      # Build plugin bundle only
./publish.sh --dry-run          # Show planned actions
```

## Provisioning

```bash
./setup/provision.sh    # Local VM setup
./ci/provision.sh       # CI environment
```

Provisioning installs both skills. By default, only extrapolation is
scheduled in OpenClaw. Divergence and agentic posture loops execute inside
EDAMAME.
