# Account group signed event foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute with tests and independent review; existing owner approval covers this development slice.

**Goal:** Provide independently verifiable device-signed group changes without granting transfer trust.
**Architecture:** Add an isolated Go accountgroup package. A stable canonical signed record is separate from HTTP session authentication and from the legacy trust graph. Approval requires both approving member and joining-device signatures over identical event bytes; membership policy and storage consume verified records in subsequent slices.
**Tech Stack:** Go standard crypto/ecdsa, elliptic P256, SHA256, encoding/json; existing auth.DeviceID identity derivation.

## Global Constraints

- Apple 登录只证明账号归属，不能单独修改设备信任。
- 每台设备保留独立设备密钥；不上传或同步设备私钥。
- 不强制登录；现有六位码配对及传输继续可用。
- 同一对设备同时拥有六位码和账号授权时，分别记录来源；撤销一个来源不误删另一个来源。
- No production, signing, portal, database, phone or legacy trust changes in this slice. No new dependencies. Preserve dirty worktree files.
- This is proof validation, not membership admission. A valid signature alone must never be described as an approved/active group member.

## Task 1: Device-signed event codec

Refinement: where the validation/test matrix below says actor!=subject or rejects self-removal, it applies to approve only. Remove permits self-removal with the same exact key; add a passing self-removal test. This supports explicit leave without requiring another device online.

Create `Services/rendezvous/internal/accountgroup/event.go` and `event_test.go` only, plus report `.superpowers/sdd/account-group-events-report.md`.

Interface contract:
```go
type Action string // bootstrap, approve, remove only
type Event struct {
 AccountID, GroupID string
 Generation, Sequence uint64
 PreviousHash []byte
 Action Action
 ActorDeviceID string
 ActorPublicKey []byte
 SubjectDeviceID string
 SubjectPublicKey []byte
 EpochMilliseconds int64
 Signature, SubjectSignature []byte
}
func (e Event) CanonicalPayload() ([]byte, error)
func (e Event) Validate() error
func (e Event) Digest() ([32]byte, error)
```

Canonical payload: JSON object with lowercase camelCase keys matching all fields EXCEPT signatures, plus `purpose` exactly `dropmesh.account.group.event.v1`. Keys sorted as standard Go map JSON; bytes represented by standard padded Base64 strings (empty previousHash is empty string, never null). Include every listed unsigned field, including both IDs and public keys. JSON escaping must match the canonical payload conventions in auth/verifier.go. No name/audience/token/private-key fields. UUIDs must be exactly canonical lowercase 36-character hyphenated hexadecimal UUID strings; don't require RFC version bits because device IDs are key hashes. P256 public keys accept existing 64-byte X||Y or 65-byte uncompressed SEC1 forms; identity uses exact original key bytes through auth.DeviceID, never silently normalizes.

Validation rules: positive timestamp, generation/sequence in1..MaxInt64 (SQL-safe). Actor and subject public keys valid P256 and IDs derived exactly. AccountID and GroupID canonical UUIDs. Bootstrap: sequence1, empty PreviousHash, actor=subject with identical key bytes, no SubjectSignature. Approve/remove: sequence>=2, PreviousHash exactly32bytes, actor!=subject. Approve requires subject DER ECDSA signature and actor DER ECDSA signature over SHA256(canonical payload); remove has actor signature only and rejects extraneous SubjectSignature. Signature fields bounded to80bytes and cryptographically valid; empty/malformed signatures rejected. CanonicalPayload performs structural validation only, allowing unsigned construction; Validate additionally validates signatures. Digest first validates, then SHA256(canonical payload) (signature-independent, so randomized ECDSA cannot fork event identity). All failures return one package sentinel ErrInvalidEvent, not detailed secret-bearing errors.

Document caller duties explicitly: Authenticate account session and actor possession; verify membership/epoch/sequence/previous hash against durably pinned history; bootstrap only after explicit owner confirmation; approve only after user fingerprint confirmation and fresh joining-device consent; scope removed-member events correctly. This codec does not check freshness, account ownership, member authority, replay, or user confirmation. No signing helper/private key custody in production.

- [ ] Write tests first: valid64/65byte bootstrap; dual-signed approve; remove; canonical exact golden bytes; digest stable across signature randomness. Failure table: tamper every unsigned field, wrong/missing actor/subject signatures, invalid/alternate identity, badpoint, uppercase UUID, extra subject signature, invalidaction, zero/overflow sequence/generation/timestamp, bootstrap hash/sequence, missing/non32 priorhash, selfapprove/remove, cross-account/group alteration. Cover input buffers unchanged. Include explicit example that valid approve still requires external membership policy.
- [ ] Run `go test ./internal/accountgroup -count=1` and retain meaningful RED. Implement minimal codec to pass.
- [ ] Run `go test -race ./internal/accountgroup -count=1`, then `go test ./...` once; report skipped SQL gates honestly.
- [ ] Self-review exact diff and commit owned files only; do not stage other files. Record test evidence, boundaries and commit in report.
- [ ] Independent task review and correction, then coordinator integration verification.

## Subsequent dependency order (not completion claims)

After proof contract review: durable pinned group state and pending approvals; authenticated account endpoints and persistence; Swift interoperable proof/client; user-confirmed native group flow; provenance-aware effective trust; cross-account request inbox and recipient target selection; two-device integration. Rebuild requires an explicitly owner-confirmed new anchor and cannot be inferred from a valid bootstrap signature. Each receives a source-grounded execution brief before implementation.
