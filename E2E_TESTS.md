# OpenClaw Intent E2E Test

End-to-end test for the OpenClaw reasoning-plane pipeline: synthetic OpenClaw-shaped
raw session payloads are built, pushed via MCP `upsert_behavioral_model_from_raw_sessions`,
and verified by polling `get_behavioral_model` until predictions appear for every
expected session key.

## What It Validates

1. **Provision checks** -- installed plugin presence at `~/.openclaw/extensions/edamame/`,
   package metadata, PSK file, repo manifest version alignment.
2. **Payload build and push** -- `scripts/e2e_build_openclaw_payload.mts` builds
   three OpenClaw-shaped sessions (`oc_e2e_api_*`, `oc_e2e_shell_*`, `oc_e2e_git_*`)
   using the plugin's `_buildRawPayload` function and pushes via MCP.
3. **Behavioral model polling** -- `edamame_cli rpc get_behavioral_model` is
   polled until the merged model contains predictions for all three session keys
   with `agent_type=openclaw` and the expected `agent_instance_id`.

## Prerequisites

- EDAMAME Security app (or `edamame_posture`) running with MCP enabled and paired
- Agentic / LLM configured (raw session ingest uses the core LLM path)
- `edamame_cli` built or installed
- `node` 18+ with `tsx` (for TypeScript payload builder) and `python3`

## Running Locally

```bash
bash tests/e2e_inject_intent.sh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EDAMAME_CLI` | auto-detect | Path to `edamame_cli` binary |
| `E2E_OPENCLAW_AGENT_INSTANCE_ID` | auto-detect | Override agent instance ID |
| `E2E_POLL_ATTEMPTS` | 36 | Number of polling attempts |
| `E2E_POLL_INTERVAL_SECS` | 5 | Seconds between polls |
| `E2E_STRICT_HASH` | 0 | If 1, require exact contributor hash match |
| `E2E_DIAGNOSTICS_FILE` | (none) | Write JSON diagnosis on poll timeout |
| `E2E_PROGRESS_POLL` | 0 | If 1, print progress to stderr each poll |
| `E2E_SKIP_PROVISION_STRICT` | 0 | If 1, skip installed-plugin check and use repo copy |
| `E2E_SKIP_REPO_VERSION_CHECK` | 0 | If 1, skip package.json vs plugin.json version alignment |
| `E2E_REQUIRE_PAIRING` | 0 | If 1, fail when only legacy PSK exists |

## Key Dependencies

- `scripts/e2e_build_openclaw_payload.mts` -- TypeScript payload builder that
  imports functions from the OpenClaw MCP plugin (`extensions/edamame/index.ts`)

## CI Integration

The `test_provisioning.yml` workflow runs this test on Ubuntu after installing
`edamame_posture`, configuring agentic LLM, and provisioning the plugin.

## Full Cross-Agent E2E Suite

The complete E2E harness (intent injection for all three agents plus CVE/divergence
scenarios) lives in the
[agent_security](https://github.com/edamametechnologies/agent_security) repo
under `tests/e2e/`. Run triggers with `--agent-type openclaw`. See
[agent_security E2E_TESTS.md](https://github.com/edamametechnologies/agent_security/blob/main/tests/e2e/E2E_TESTS.md)
for the full architecture.
