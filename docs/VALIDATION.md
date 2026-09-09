# Validation Matrix

| Area | Check | Mechanism | Expected result |
|---|---|---|---|
| Helper contract | Validate registered tool surface, session filtering, and payload trimming | `npm test` | OpenClaw helper functions behave deterministically and preserve the expected EDAMAME payload contract |
| Install smoke | Verify local install paths | `bash setup/install.sh` or `pwsh ./setup/install.ps1` | plugin and skills are copied into the expected OpenClaw directories and plugin enablement succeeds or degrades clearly |
| Plugin contract | Validate plugin manifest, structure, and helper exports in CI | `.github/workflows/tests.yml` | manifest, structure, install, unit tests, and plugin export checks pass on Linux, macOS, and Windows |
| Provisioning E2E | Retired in EDAMAME 1.7.0 | `.github/workflows/test_e2e.yml` (stub) | see [edamame_posture fleet monitoring](https://github.com/edamametechnologies/edamame_posture_cli/blob/main/tests/e2e/E2E_TESTS.md) |
| VM stack | Validate full Lima flow manually | See [openclaw_security](https://github.com/edamametechnologies/openclaw_security) `setup/` | OpenClaw, EDAMAME Posture, the MCP endpoint, and the plugin all come up together |
| Workstation pairing | Validate app-mediated pairing path | `./setup/pair.sh` plus app approval | the local credential is stored and subsequent plugin calls authenticate successfully |

## Recommended Local Sequence

1. `npm test`
