# Native adapter review:8de36d2..e303652

Spec: truthful storage-error reporting incomplete. Task quality: Needs fixes.
Reviewer iphone_native_picker_review (gpt-6-astra),2026-09-12.

Important: MobileImportService.swift:17-26 maps actual POSIX disk-full errors
to provider unavailability. MobileImportCopy.swift:47,143-144,155 throws
POSIXError for destination creation/write/finalization. ENOSPC should show
storage guidance, preserving source-access distinctions. Existing native test
MobileImportAdapterTests.swift:59-70 covers Cocoa disk-full only. Add actual
error-domain regression and correct mapping before accepting adapter gate.

Strengths: lazy trusted factory and serialized fresh attempts
(MobileImportService:55-63,86-110); exact stager/task retention and copy completed
inside importing callback (:112-138); provider/factory/worker join and retryable
failed cleanup (:155-202); file-only Photos representation/cancel-before-Progress
registration/nil-unsupported (MobilePhotoImport:7-14,31-77); multi-file import and
synchronous duplicate gate (MobileFilesPicker:33-50); real bytes/streaming/factory
tests with bounded gates (MobileImportAdapterTests:72-130).

No Critical. Minor: disclosed AppIntents extraction warning remains final-review
ledger item, not functional blocker. Physical Photos/iCloud, future send borrower
joining, navigation/lifecycle and installed acceptance remain subsequent gates.
Provider completion is a lifetime boundary assumption, not cancellation proof
from real Photos. Reviewer read frozen diff once4chunks; no git/writes/tests or
changed-file rereads. One focused outside check read actual importer error
propagation/throw sites. Root separately checked60unit+3UI/buildsuccess logs;
these remain source/inert evidence, not actual provider acceptance.
