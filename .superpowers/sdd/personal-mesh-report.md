# Personal mesh implementation report

Status: local implementation PASS; real two/three-Mac acceptance NOT RUN; runtime privacy BLOCKED.

## Scope completed

- Tailscale CLI discovery and route evidence with bounded output/time and no logged raw status.
- Exact owned `serve --tcp 51337 tcp://127.0.0.1:51338` configuration.
- Probe, bilateral pairing, signed trust persistence, revocation and per-device connection ownership.
- Production mesh transfer connector/source using signed ephemeral ECDH and encrypted ordered frames.
- App settings and runtime selection between personal mesh and public service modes.
- Developer ID signed read-only DMG plus exact manifest, failure cleanup and install smoke test.
- Two-client production mesh integration for file, directory, collision, capacity, permissions,
  ciphertext tamper, revocation, three-device targeting and 64 MiB restart/resume.

## TDD evidence

The first distribution contract run failed because `Scripts/build-distribution.sh` did not exist.
The first personal mesh integration compile failed with `cannot find 'PersonalMeshHarness' in scope`.
After implementation, the focused suite executes seven tests with zero failures. The 64 MiB test
closes the real in-memory transport, closes/reopens SQLite, reloads the identity and authenticated
trust snapshot from disk, creates a new candidate directory/registry/connector/coordinator, retains
the same TransferID, decodes a nonempty receiver ResumeMap, and bounds all wire bytes on subsequent
connections. A from-zero mutant fails the same predicate.

## Current artifact

- Release state: `internalSignedNotNotarized`
- Developer ID Team: `XKAZ67HN45`
- Public notarization: BLOCKED because no notary profile was supplied.
- Real Mac rows: NOT RUN until the same artifact is installed on Mac A/B/C.

## Privacy

Static mutants reject Tailscale IP, MagicDNS/hostname, pairing code, fingerprint, CLI stdout/stderr,
private key, filename/path and content logging in Swift, Go and shell. Fixed-category helper failures
do not print the underlying error string. Runtime privacy remains status 2 BLOCKED; no self-signed or
handwritten evidence can produce PASS.
