# Account release data inventory (pre-release, not published policy)

Source inspection on current development mainline. This records implementation
facts for the later privacy/review update; it does not claim production activation,
legal compliance, deletion completeness or Store metadata changes.

| Feature | Source fact | Release follow-through |
| --- | --- | --- |
| Apple login | MobileAppleAuthorization requests no name/email scopes | Do not imply collection of Apple name/email through login; support email remains separate |
| Account identity | Migration009 stores account UUID, Apple subject, status and creation time | Disclose optional account identifier and purpose; account-enabled version is not anonymous-only |
| Credentials | Encrypted Apple refresh credential bound to device/audience; access/refresh hashes, session families and replay/issuance registry | Explain security/session purpose without claiming immediate erasure or publishing secrets |
| Group membership | Migration010 stores group anchor and signed event journal | Describe account-linked device membership and security history; not file-content cloud storage |
| Approval requests | Migration011 stores device/public key, bound sessions/audiences, five-minute expiry and signed draft/event states | Expiry is not proof of database deletion; do not invent a retention deadline |
| Account deletion | No integrated deletion operation found in native controller or account HTTP source in this inspection | Must finish and verify deletion/revocation UX before account-enabled release; adapter alone is insufficient |

Existing AppStore/metadata/privacy.md is dated 16 September and describes the
manual-pair release. Its statement that an account is not required can remain
accurate if login stays optional, but it omits account/group processing. Preserve
current published policy until the account release's actual behavior is finalized;
then update both EN/ZH and verify hosted content and App Store privacy answers.

Do not equate logout, removing a device, rebuilding identity, clearing local history
and deleting an account. Each has different retained files, manual pairs, remote
sessions and journal effects that must be documented against actual tests. Current
backup statement has no universal deletion deadline and must not be tightened
without corresponding operational evidence.

Apple official requirements rechecked20 September2026:
[Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app)
requires in-app initiation of account deletion and Apple-token revocation for
Sign in with Apple apps. [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
is the provider integration reference. These requirements do not establish that
this branch's deletion workflow is implemented or accepted by App Review.
