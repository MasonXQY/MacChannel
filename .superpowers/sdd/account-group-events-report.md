# Account group event codec report

## Scope and result

Implemented the standalone device-signed account group event codec in
`Services/rendezvous/internal/accountgroup`. The codec provides deterministic
canonical JSON, structural validation for unsigned construction, actor and
joining-subject P-256 signature verification, and signature-independent event
digests. Both existing 64-byte X||Y and 65-byte uncompressed SEC1 public keys
are accepted without normalization; device identity and signed bytes retain the
exact supplied representation.

Per the coordinator's refinement, removal may be self-removal when actor and
subject identity/key bytes are identical. Approval still rejects actor=subject.

## TDD and verification evidence

- RED: `go test ./internal/accountgroup -count=1` failed because the new
  `Event`, `Action`, and action constants did not exist.
- GREEN: `go test ./internal/accountgroup -count=1` passed (`1.483s`).
- Race: `go test -race ./internal/accountgroup -count=1` passed (`1.500s`).
- Full default Go suite (run once): `go test ./...` passed; accountgroup passed
  in `0.349s` and all other default packages passed or had no tests.
- `git diff --check` passed for owned paths.
- SQL-enabled gates were not run: this codec adds no SQL or persistence and the
  requested full check was the default suite.

Tests use only ephemeral P-256 fixture keys and cover 64/65-byte bootstrap,
dual-signed approval, third-party and self removal, exact canonical bytes,
signature-independent digest, unsigned payload construction, full unsigned-field
tampering, signature failures/bounds, identity mismatch and bad points, strict
UUIDs, action/number/history invariants, unchanged input buffers, and the fact
that a cryptographically valid approval still needs external membership policy.

## Security and caller boundaries

`Validate` proves only event structure, exact key-derived identities, and the
required signatures. Callers must authenticate the account session and actor
possession; compare membership, generation, sequence, epoch, and previous hash
with durably pinned history; require explicit owner confirmation for bootstrap;
require user fingerprint confirmation and fresh joining-device consent for
approval; and correctly scope events visible to removed members. The codec does
not establish freshness, account ownership, member authority, replay protection,
or user confirmation. It contains no signing helper and takes custody of no
private key. Legacy six-digit pairing/trust and routing are untouched.

## Owned files

- `Services/rendezvous/internal/accountgroup/event.go`
- `Services/rendezvous/internal/accountgroup/event_test.go`
- `.superpowers/sdd/account-group-events-report.md`
