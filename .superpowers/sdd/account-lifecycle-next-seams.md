# Account lifecycle remaining implementation seams

2026-09-20 root read-only source check; not completed features or an execution brief.

- accountgroup.PostgresStore.Append is explicitly caller-authorized and session-
  unaware. Its accepted signed remove event is not a user-facing remove-device API.
  A lifecycle mutation needs exact session/device validation under the same group
  advisory and account lifecycle lock, plus targeted session-family revocation.
- group_http.go exposes Events read through AccountGroups. Native session controller
  currently has logout/storage removal, not remove-device/rebuild/delete-account.
  Do not present these UI controls as complete based on journal action support.
- AppleRevoker is only a provider adapter. Integrated deletion needs durable retry
  state and actual data erasure plus sessions/invitations/derived authorization
  withdrawal. Deactivation alone cannot meet the approved design.
- Rebuild must be a separately confirmed new group generation with stale-device
  invalidation, not a larger generation accepted as an ordinary sync update.
- Manual and account authorization are independent sources. Lifecycle operations
  must preserve received files and unrelated six-digit pairings.

Next scoped planning should bind these to the current session lock and routing
admission contracts after the pending components pass independent review. No live
state or source was changed by this inspection.
