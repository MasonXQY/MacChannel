# Account credential primitives implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute tasks sequentially with independent review.

**Goal:** Supply short-lived Apple developer signatures and authenticated encryption for Apple refresh credentials before persistence/session integration.

**Architecture:** Two standalone accountauth components use standard-library cryptography, configuration supplied in memory and no network/disk access. The signer implements the existing AppleClientSecretProvider; the protector binds ciphertext to its intended credential record. Neither is an account session, database or trust grant.

**Tech Stack:** Go module 1.25+, standard crypto/ecdsa, crypto/x509, crypto/aes, crypto/cipher. Local runtime Go1.27. No new dependencies.

## Global Constraints

- Preserve submitted iOS 1.0(8), installed clients, existing routes, pairing protocol and production service.
- No real credentials, device private keys, portal mutations, production requests, native app updates or dependencies.
- Apple identity alone does not grant device trust.
- Keep unrelated dirty files intact and out of commits.
- These primitives do not establish protected persistence, revocable sessions or live Apple login; document those remaining gates.

### Task 1: Short-lived Apple developer client-secret provider

**Files:** Create `Services/rendezvous/internal/accountauth/apple_client_secret.go`, `apple_client_secret_test.go`, `docs/acceptance/account-client-secret-20260917.md`.

**Interface:**
```go
func NewAppleClientSecrets(teamID, keyID string, privateKeyPEM []byte, audiences []string) (*AppleClientSecrets, error)
func (p *AppleClientSecrets) ClientSecret(ctx context.Context, audience string) (string, error)
var _ AppleClientSecretProvider = (*AppleClientSecrets)(nil)
```

- [ ] Write compiling stub plus a real crypto assertion-failing test. Generate synthetic P256 key and marshal PKCS8 PEM in the test. Decode resulting JWT with standard base64/JSON and verify signature with ecdsa.Verify against original public key; check exact header and claims. Record assertion RED, then implement.
- [ ] Constructor validates teamID/keyID exactly10 uppercase ASCII alphanumeric; audiences1..16 unique, valid UTF8,1..255bytes no whitespace/control (reuse validLoginCredential). Reject PEM empty/>16KiB, leading/trailing nonwhitespace data, multiple blocks, encrypted or wrong PEM type/headers, anything except PKCS8 `PRIVATE KEY` containing P256 ECDSA key. Validate scalar in(0,N), curve P256, public point and scalar/public correspondence; retain private parsed copy, never caller input buffers. Do not read a path/envvar or generate fallback key. All failures nil+generic sentinel without contents.
- [ ] Implement ClientSecret: reject nil receiver/context, canceled context, unallowlisted audience. Private clock=time.Now production, test seam unexported. Serialize clock read/signing with mutex; reject nonpositive Unix seconds, outside year9999, or time rollback vs prior successful issuance (equal time allowed), checked expiry arithmetic. Emit fresh compact JWT per call, rawbase64url canonical, header exactly alg ES256/kid; claims exactly iss=teamID,sub=requestedallowlistentry,aud=https://appleid.apple.com,iat=now.Unix(),exp=iat+300. Sign SHA256(header.payload) with owned P256 key and standard crypto/rand; signature fixed64byte r||s, not ASN1. Context checked before return; error yields empty string+generic sentinel. No cache, files or logging. String/GoString of provider redact key material. Document concurrent-safe provider, startup configuration immutable and sensitive returned string must not be logged. Rotation means constructing provider with new key; existing provider unchanged.
- [ ] Tests: real signature+exact claims/TTL; two audiences; unknown audience; invalid IDs/allowlist; bounded malformed PEM, multiple block, leading garbage, wrong headers/type, RSA/P384/SEC1 rejection; caller PEM/allowlist mutation cannot change provider; nil and canceled; time0/year10000/rollback rejected; sameclock allowed; concurrent valid issuance (not asserting nondeterminism); provider fmt redaction; no output on every failure. Native coordinator integration: use existing synthetic loginFixture, replace fake secret provider with real provider and have synthetic token transport cryptographically verify client_secret plus subject/audience before returning valid Apple result. No live network.
- [ ] Run focused tests, accountauth race, full default Go once; record SQL skips. Commit only owned files and write `.superpowers/sdd/task-1-report.md` with RED/GREEN, commands, evidence, limitations.

Implementation scaffold guidance:
```go
digest := sha256.Sum256([]byte(headerPart + "." + payloadPart))
r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
if err != nil { return "", ErrAppleClientSecret }
signature := make([]byte, 64)
r.FillBytes(signature[:32]); s.FillBytes(signature[32:])
```
Go1.27 ignores the random Reader in ecdsa.Sign unless special debug mode; do not introduce fake entropy assertions relying on ignored Reader or change global crypto configuration. Use real crypto checks.

### Task 2: Record-bound Apple refresh-token encryption

**Files:** Create `Services/rendezvous/internal/accountauth/apple_credentials.go`, `apple_credentials_test.go`, `docs/acceptance/account-credential-protection-20260917.md`.

**Interface:**
```go
type AppleCredentialBinding struct { Subject, Audience, DeviceID, CredentialID string }
func NewAppleCredentialProtector(activeKeyID string, keys map[string][]byte) (*AppleCredentialProtector, error)
func (p *AppleCredentialProtector) Seal(ctx context.Context, binding AppleCredentialBinding, refreshToken string) ([]byte, error)
func (p *AppleCredentialProtector) Open(ctx context.Context, binding AppleCredentialBinding, envelope []byte) (string, error)
```

- [ ] Write compiling stub+roundtrip assertion RED before implementation, then security mutations. Use only synthetic keys/tokens; no files/databases.
- [ ] Constructor keys1..8, keyID1..64ASCIIalnum/_/-, each AES25632bytes, active exists. Copy configuration; create aes.NewCipher + cipher.NewGCMWithRandomNonce for each. No user encryption algorithm/nonce choice, no fallback/default/random encryption key. Redact provider fmt; configuration immutable, concurrency-safe. Reject invalid config generic error nil.
- [ ] Validate bindings on Seal/Open: subject1..255bytes validUTF8 (match validator, no trim/casefold), audience validLoginCredential1..255, DeviceID canonicallowercaseUUID (reuse current validBinding via scoped map or tiny shared helper only if approved), CredentialID same canonicalUUID. Context nonnil/noncanceled. Token validLoginCredential1..16384. No general purpose opaque-input encrypt API.
- [ ] Envelope byte format: version1 (one byte), keyIDlength(one byte), keyIDbytes, then standard AEAD output (random12nonce+ciphertext+16tag). AAD is JSON encoding of string array `["dropmesh:apple-refresh:v1", keyID, binding.Subject, binding.Audience, binding.DeviceID, binding.CredentialID]`; never concatenate unframed values. Entire prefix keyID/version checked before decrypt. Open bound total size: token1..16384 plus overhead28 plus prefix/keyID. Unsupported version/key, badlength/truncated/tag/ciphertext/nonce/context => empty string+same generic sentinel; Seal failure=>nil+sentinel. Recheck context before returning. Open revalidates decrypted token syntax/size. No plaintext fallback or partial output. Keep keyIDs in envelope for bounded rotation: configured old key can decrypt, new seals useactive, removedkeysfailclosed. Use no raw key in AAD/envelope.
- [ ] Tests: real roundtrip; tamper every envelope region; all binding field changes with otherwisevalidbindings reject; different key withsameID reject; unknown/version/length/truncation/oversize; no plaintextfallback; valid1byte/max token, invalidtypes/UTF8/whitespace/empty; copied keymap/keybytes; rotation retainold thenremove; concurrency/race; ctxcancel; configinvalid. Assert output nil/empty on all failures. Golden format inspection independently decode prefix and decrypt via standard AEAD with independently constructed AAD, plus Seal-independent stdlib ciphertext accepted by Open. No self-roundtrip-only confidence.
- [ ] Run focused tests, accountauth race, full default Go once. Commit only owned files. Report `.superpowers/sdd/task-2-report.md` and acceptance doc. Document: persistence/key custody/rotation rollout are not implemented; operator must keep masterkeys separate from DB/backups and rotate before2^32encryptions/key. This bounded primitive has no durable per-key use counter, replay/rollback prevention, database or session authorization.

Standard-library construction:
```go
block, err := aes.NewCipher(keyBytes)
if err != nil { return nil, ErrAppleCredential }
aead, err := cipher.NewGCMWithRandomNonce(block)
// AEAD.NonceSize()==0; Seal/Open nonce argument nil, nonce managed by stdlib.
```

## Sources / scope review

Apple Token validation JSON currently references Creating a client secret at
https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret;
root followed that exact reference and read Markdown on2026-09-17. It documents
ES256, kid, iss, sub, aud and epoch times. Our five-minute lifetime is a local
conservative choice, not Apple's maximum. Sign-in-specific key association:
https://developer.apple.com/documentation/signinwithapple/configuring-your-environment-for-sign-in-with-apple

Local `go doc crypto/cipher.NewGCMWithRandomNonce` confirms random96bitnonce,
28byteoverhead and atmost2^32messages/key. Do not claim this primitive proves
durable credential security before real key custody and persistence integration.

No new user product decision is introduced; this implements the approved
credential-protection boundary. Revocable sessions, deletion, group membership,
invitations and native integration remain subsequent independent tasks.
