# Independent Share review a7712c6..f57aa0a

Spec issues found; quality Needs fixes. No Critical; three Important:

1. iPhone/project.yml43: individual .lproj paths generated no extension Resources
   build phase. Both actual embedded bundles contain no localization resources;
   labels can display keys. Inert TestHost has resources and masks the defect.
   Fix target membership, regenerate and verify actual built EN/ZH string lookup.
2. ShareBatchStore59: crash after UUID mkdir before .lock creation, or after .lock
   unlink before rmdir, leaves lockless entries skipped forever by cleanup yet
   counted toward20 capacity. Recover validated stale lockless states while
   coordinating against live initialization/deletion; test exact interruption states.
3. ShareBatchStore142 / unchanged MobileImportCopy129: pre-stat closes the source
   and copier reopens/reads until EOF with no byte ceiling. Replacement/growth can
   exceed2GiB/file or remaining4GiB/batch before rejection. Obtain additive bounded
   copy API and enforce allowance in actual streaming; use small deterministic tests.

Strengths: provider importing closure awaits copy and retains cancellation owner;
atomic readiness after complete bounded manifest; explicit pending import without
automatic send; real malformed/traversal/symlink/FIFO/concurrent claim tests.

Reviewer read frozen diff once. Named outside checks: actual simulator/device
appex resource inventories and pure importer API for size TOCTOU. No writes,
git, tests or builds. Physical hosts/AppGroup/signing/locked behavior/actual
interop and upstream trust/foreground guarantees remain separate gates.
