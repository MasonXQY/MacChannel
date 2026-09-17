# Signed account HTTP root acceptance

Initial code `8c8b74b`; correction `fc17ac8`; independent final task review Approved with no blocking findings. Root final fresh SQL-enabled `go test -race ./internal/accountauth ./internal/httpapi -count=1`: PASS accountauth27.874s / httpapi3.135s, after correction.

The initial SQL-enabled run26.483s/3.802s passed but did not expose the native public-key mismatch. Root reproduced CryptoKit publicKey.rawRepresentation=64 bytes with an ephemeral synthetic key. Initial handler accepted only65; corrected handler accepts existing64 X||Y and65 legacy form through the unchanged verifier. Product identity and device-ID hashing stay unchanged.

Independent review additionally identified infrastructure errors collapsed into401 and incomplete adapter assertions. Corrected code adds a generic unavailable sentinel preserving errors.Is(ErrAppleLogin), maps it to503 before authentication errors, keeps known invalid Apple credentials401, and never exposes provider error bodies. Meaningful REDs and real-coordinator/fake-provider HTTP checks, exact input/order/result propagation, global/source capacity, cancellation and slot release are in `.superpowers/sdd/account-http-task-11-report.md`.

Only optional router mounting was added; main does not construct account services. No production endpoint, Apple capability/key, native login, install or Store review changes occurred. This is not true Apple or phone acceptance. Native client Task12 starts fromfc17ac8. Existing review IPA hash rechecked unchanged436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9.
