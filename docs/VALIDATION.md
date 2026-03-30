# Validation Matrix

| Area | Check | Mechanism | Expected result |
|---|---|---|---|
| Helper contract | Validate payload trimming, filtering, traffic extraction, and stable agent identity logic | `npm test` | OpenClaw helper functions behave deterministically and preserve the expected EDAMAME payload contract |
| Install smoke | Verify local install paths | `bash setup/install.sh` or `pwsh ./setup/install.ps1` | plugin and skills are copied into the expected OpenClaw directories and plugin enablement succeeds or degrades clearly |
| Intent injection E2E | Push OpenClaw-shaped raw sessions and poll the merged model | `bash tests/e2e_inject_intent.sh` | injected `session_key` values appear under `agent_type=openclaw` and the expected `agent_instance_id` |
| Plugin contract | Validate plugin manifest, structure, and helper exports in CI | `.github/workflows/tests.yml` | manifest, structure, install, unit tests, and plugin export checks pass on Linux, macOS, and Windows |
| Provisioning E2E | Verify posture-backed setup and intent injection in CI | `.github/workflows/test_e2e.yml` | provisioning, posture startup, pairing, healthcheck, and intent-injection checks succeed in the CI topology |
| VM stack | Validate full Lima flow manually | `setup/provision.sh` in a VM created from `setup/lima-example-openclaw.yaml` | OpenClaw, EDAMAME Posture, the MCP endpoint, and the plugin all come up together |
| Workstation pairing | Validate app-mediated pairing path | `./setup/pair.sh` plus app approval | the local credential is stored and subsequent plugin calls authenticate successfully |

## Recommended Local Sequence

1. `npm test`
2. `bash tests/e2e_inject_intent.sh`
3. If using a VM flow, run `setup/provision.sh` inside the target Lima environment
