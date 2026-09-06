# DropMesh synthetic privacy evidence verifier

This standalone macOS tool checks the integrity and internal consistency of an offline, synthetic evidence fixture. It does not collect evidence, attest that observations are true, evaluate privacy semantics, use a production trust root, or approve an App Store release.

## Command

```text
privacy-evidence verify-fixture --bundle DIR --test-policy FILE --now YYYY-MM-DDTHH:MM:SSZ
```

All three flags are required exactly once. Their order may vary. The UTC value must use the exact shown form. There is no production command, implicit clock, environment-variable override, signing command, network access, or automatic trust enrollment.

The bundle is a flat directory containing `manifest.json`, the raw 64-byte `manifest.sig`, and the signed artifact inventory. The separate test policy is canonical JSON with exactly these top-level fields:

- `schemaVersion`
- `keys`

Each item in `keys` has exactly `id`, `publicKeyHex`, `notBeforeUTC`, `notAfterUTC`, and `revoked`. See the approved verifier design for the complete manifest and receipt fields and constraints.

The tool emits exactly one fixed line:

- Exit 0: `FIXTURE_INTEGRITY_OK_NOT_RELEASE_APPROVAL`
- Exit 1: `FIXTURE_REJECTED:schema|policy|signature|inventory|receipt|time`
- Exit 2: `PRIVACY_VERIFIER_BLOCKED:usage|unsafe-input|unavailable-input|internal`

Input paths, fixture content, IDs, digests, public keys, parser errors, and environment values are never included in output. Files are opened without following links and are bounded before reading: manifest 64 KiB, policy 16 KiB, signature exactly 64 bytes, receipt and canaries 64 KiB each, other artifacts 16 MiB each, and the whole bundle 128 MiB.

## Offline verification

The module has no third-party dependencies. On macOS, run:

```sh
cd Tools/PrivacyEvidenceVerifier
GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go test ./...
GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go test -race ./...
GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go vet ./...
cd ../..
bash Scripts/test-privacy-verifier-contract.sh
```

Tests generate Ed25519 keys only in memory and materialize synthetic fixtures in temporary directories. No test or command uses a production key. A successful result proves only that one caller-supplied synthetic bundle is structurally valid and signed by a key in its caller-supplied test policy; all production privacy and release gates remain blocked.
