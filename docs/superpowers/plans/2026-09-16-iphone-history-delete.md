# iPhone history deletion implementation plan

Goal: approved single swipe, multi-selection and clear-all history with explicit
confirmation; retain payload files, paired devices and active transfers.

Architecture: mobile-only persistent history deletion markers separate from the
transfer engine's recovery records. Session accepts IDs or nil for all eligible
records. List and action resolution respect deletion after restart. No filesystem
payload removal and no Mac history behavior change.

- [ ] Backend: add `deleteHistory(ids: Set<TransferID>?) async throws` session
  operation, mobile runtime filtering/markers; nil covers ALL eligible records,
  not just current list limit. Protect active states. Test restart and repeat
  snapshot writes, all-history beyond limit, failed persistence, source files intact.
- [ ] App model: delete only after confirmed action; serialize deletion, invalidate
  stale refreshes/actions, clear affected read markers and refresh. Show failures.
- [ ] UI: swipe single record, Edit with selection, delete selected, clear all.
  Confirmation explicitly says files/photos are kept; cancel changes nothing.
  EN/ZH copy; accessible controls; selection IDs stable across refresh.
- [ ] Verify unit/UI tests, independent review, signed generic-device build and
  overwrite-install connected phone without reset. No TestFlight upload.

User approved this interaction contract in conversation on 2026-09-16.
