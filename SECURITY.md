# Security Policy and Scope

This repository is currently a private preview. Security guidance is focused on
safe evaluation and bounded claims.

## Security Contact

For private disclosure while this project is private, use internal EDAMAME
security channels and include:

1. affected component
2. reproducible steps
3. observed impact
4. recommended mitigation

## Scope

In scope:

- `skill/edamame-extrapolator/*`
- `skill/edamame-posture/*`
- setup and test scripts in `setup/` and `tests/`
- documentation describing security behavior

Out of scope:

- vulnerabilities in upstream OpenClaw core itself
- vulnerabilities in EDAMAME Posture core implementation
- generic prompt injection claims without reproducible impact in this repo

## Assumptions

The PoC assumes:

- OpenClaw and EDAMAME Posture run on the same endpoint
- gateway auth and local host hardening are already configured
- manual confirmation mode is used for action execution
- operators review high-risk escalations before remediation

## Safe-Use Requirements

1. keep `gateway.bind` on loopback unless explicitly required
2. keep OpenClaw and EDAMAME Posture on patched versions
3. keep MCP PSK secret, local, and permission-restricted
4. treat all third-party skills as untrusted by default
5. do not claim production detection coverage from PoC-only validation

## Known Limitations

- benchmark metrics are currently internal trace-backed artifacts (see `artifacts/live-paper-summary.json`, `artifacts/live-paper-manifest.json`, and `docs/CLAIM_ARTIFACT_INDEX.md`)
- no third-party audit or penetration test for this repo yet
- hosted CI relies on a `limactl` shim for VM-dependent paths; real-VM lifecycle coverage runs in the scheduled self-hosted `tests.yml` `real_lima` lane
- tests are mostly integration/readiness checks and benchmark harnesses, not formal adversarial proofs

## Disclosure Handling Target

- acknowledge report: within 2 business days
- triage severity: within 5 business days
- mitigation plan: as soon as reproducible impact is confirmed
