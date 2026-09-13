# Final pairing/reconnect program review

Review baseline: `f93a82a`. Controller supplies the final head and generated diff package after all task gates. This is a whole-program security/concurrency and integration review, not a release or physical acceptance claim.

## Requirements

Read `docs/acceptance/pairing-reconnect-audit-2026-09-13.md` for approved scope and `docs/acceptance/pairing-reconnect-final-runbook-2026-09-13.md` for final gates. Binding compatibility constraints, verbatim:

不是全部重写。保留 DeviceID、密钥、既有签名证明、撤销、防重放与传输协议；
不增加账号、Tailscale 依赖或自动重新授权，不按名称合并设备。

身份会话、信任同步、配对事务、设备可达分别建模。Mac/iPhone 共用会话与恢复
规则，平台适配层只处理生命周期、网络和界面。

利用现有身份认证和信任更新报文分离连接/同步。身份可连接不等于获得 peer
路由或传输权限；信任图及撤销校验继续独立强制执行。旧客户端保持兼容。

同步须收到确认后推进；仅发送到 socket 不算同步完成。串行关联、超时与晚到
确认须有明确策略。失败不自动丢弃撤销记录、不重新签发授权。

配对阶段明确为等待对方、提交、保存、待同步、已配对或可恢复失败；落盘失败
不显示完成。跨设备不能保证瞬时原子成功，断点状态必须可重试并最终收敛。

短暂失联显示连接中/状态待确认；服务不可用不能直接归因为对方离线。
在线状态不承诺本次文件一定可传输；实际发送仍须验证信任和端到端链路。

## Change areas / evidence

Task reports in `.superpowers/sdd/`: trust-snapshot-report.md, shared-presence-owner-report.md, identity-trust-sync-report.md, durable-pairing-surface-report.md, durable-trust-publication-report.md, presence-presentation-report.md, shared-owner-live-interop-report.md. Treat reports as claims and verify against the diff.

The first real shared-owner live gate at `a03ef7c` exposed valid peer→owner revocation causing `cannotRevokeOwner` and a reconnect. Include the corrective plan `docs/superpowers/plans/2026-09-13-peer-revocation-catchup.md` and its report `.superpowers/sdd/peer-revocation-catchup-report.md`. Inspect issuer-only trust narrowing, unchanged owner identity, validation-before-mutation, replay/high-water and durable negative proof/re-pair behavior across restart. The failing integration commit is regression evidence, not an accepted gate; require the reported final passing live run.

Root evidence: `docs/acceptance/pairing-reconnect-local-evidence-2026-09-13.md`; program cursor is the final section of `.superpowers/sdd/progress.md`. Earlier unrelated iPhone iteration sections are not this review's scope.

Recorded remaining qualifications: existing Xcode AppIntents metadata-extraction warning; original live HTTP transport fixture warnings about shared-session invalidation unless separately corrected. Presence visual evidence has a root-inspected report `docs/acceptance/presence-presentation-visual-review-2026-09-13.md`; largest text needs native scrolling. The live test initializes verified static directory trust to avoid introducing a test observer that lacks an explicit stop/join API; this test does not establish dynamic DeviceDirectory trust-observer teardown.

Inspect cross-task interactions, particularly:
- coherent server snapshot/high-water/version recovery and concurrent mutation;
- identity-only admission versus independently enforced bilateral authorization;
- one active owner, drained old socket/readers/heartbeat/liveness/delivery/persistence operations before replacement;
- full saved/current signed-record intersection, ACK correlation, timeout, revocation and unsaved/superseded record races;
- durable pairing save/retry lifecycle and actual Mac/iPhone runtime wiring;
- authentic connectivity versus storage failure, conservative sync reset, state-to-row updates and no presentation-to-permission shortcut;
- live Swift shared-owner / real Go router test coverage and cleanup.

Known boundary requiring accurate wording: `MobileDurableTrust` is a UI admission filter; incoming transport still reads repository trust through existing ReceivePolicy and cryptographic checks. Durable publication is not a newly promised durable incoming-admission policy. Evaluate integration safety and report concrete defects rather than assuming the presentation filter secures transport.

## Review method / deliverable

Use the provided diff package and focused surrounding-code checks where a concrete cross-cutting risk warrants them. Do not mutate source, index, HEAD or running apps. Do not repeat full suites already reported; if code raises an unanswered specific doubt, describe or run only the focused check without colliding with controller builds.

Return one consolidated report with file:line references, strengths, all Critical/Important/Minor findings and an explicit readiness verdict. Distinguish source readiness from signed installed or production verification; neither has happened merely because local tests pass. Controller records your response and resolves findings in a single fix wave before final acceptance.
