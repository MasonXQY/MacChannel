# Mac 通道生产部署与回滚

本手册面向单区域首版。生产发布必须使用独立域名、受信任 TLS、托管 PostgreSQL 17
或等价受控实例，以及可从公网到达的 coturn。不要把本地开发 CA 或默认 secret 用于生产。

## 发布前输入

- 已批准的 Git commit、签名且公证的 `.app`、上一版可回滚构建。
- rendezvous/coturn/迁移镜像的不可变 digest 和 SBOM。
- `rendezvous.example.com` 与 `turn.example.com` 的 DNS 控制权。
- TLS 证书、TURN REST shared secret、数据库凭据和轮换负责人。
- 至少两台真实 Mac、第三台配对设备和 Task 14 验收窗口。

## 网络与 DNS

1. 为 rendezvous 建立 A/AAAA 记录，TTL 在切换前降至 300 秒。
2. 为 TURN 建立独立 A/AAAA 记录；advertised relay IP 必须等于公网一对一映射地址。
3. 开放 rendezvous `443/TCP`。
4. 开放 TURN `3478/UDP`、`3478/TCP`、`5349/TCP`（TLS）和中继范围
   `49160-49200/UDP`。若启用 TURN/TCP relay，按实际 coturn 配置另行开放且记录。
5. PostgreSQL `5432/TCP` 只允许 rendezvous 私网安全组访问；metrics 端口只允许监控网访问。
6. 验证 IPv4 与 IPv6、NAT 映射、防火墙回程和 MTU；不得开放 coturn CLI。

## TLS

- 使用公开受信任 CA；证书 SAN 精确覆盖各服务域名，不使用通配符代替 TURN 身份审查。
- rendezvous 只提供 HTTPS/WSS；关闭明文外部入口和旧 TLS 版本。
- coturn TLS listener 使用独立证书和私钥，私钥以只读 secret 注入。
- 到期前 30 天告警，轮换时先部署新证书并完成双端验证，再撤销旧证书。
- 客户端发布前将生产 WSS URL 写入受审查的运行配置。

## PostgreSQL 迁移

1. 创建加密快照并演练恢复；记录快照 ID 和恢复耗时。
2. 在 staging 的 PostgreSQL 17 顺序执行 `Services/migrations/001...005`。
3. 检查事务成功、索引存在、无意外表锁和未受控 schema drift。
4. 生产先部署向后兼容迁移，再滚动 rendezvous；禁止跳号。
5. 迁移后验证 `/healthz`、配对创建/过期、信任传播与 replay 拒绝。
6. 数据迁移不可逆时，回滚使用发布前快照恢复到隔离的新实例，不在原库做猜测性 DOWN SQL。

## Secret 轮换

- 数据库凭据：创建新角色/密码，双凭据窗口内滚动 rendezvous，确认旧连接排空后撤销旧角色。
- TURN shared secret：支持双 secret 时先添加新 secret；否则安排短维护窗，同时更新
  rendezvous 与 coturn。旧十分钟凭据自然过期后销毁旧 secret。
- TLS 私钥：通过 secret manager 生成/导入，文件 `0400`、最小 UID 可读；禁止写入镜像、Git 或日志。
- 每次轮换记录时间、负责人、secret version 和验证结果，不记录 secret 值。

## 部署顺序

1. 固定并验证镜像 digest，运行 Go race/vet、Swift 全套和 `Scripts/verify-e2e.sh`。
2. 备份数据库并应用迁移。
3. 部署 coturn，验证 Allocate、relay 地址和端口范围。
4. 部署 rendezvous，验证健康、WSS 认证、TURN 临时凭据和配对 TTL。
5. 用内部签名客户端完成 direct 与 forced-relay canary。
6. 分阶段发布签名、公证客户端：内部、少量设备、全部设备；每阶段观察至少一个凭据 TTL。
7. 完成真实 Mac 验收与隐私运行时审计后才宣布可用。

## 健康、容量与告警

- rendezvous：`/healthz`、请求延迟、5xx、WebSocket 在线数、认证/速率限制错误类别。
- PostgreSQL：连接数、事务错误、锁等待、磁盘、WAL、备份新鲜度和 expiry 清理积压。
- TURN：Allocate 成功率、当前 allocation、relay 带宽、端口池利用率、认证失败和 TLS 到期。
- 告警建议：5 分钟健康失败；5xx > 2%；端口池或 allocation > 80%；带宽超过合同
  80%；数据库磁盘 > 75%；备份超过 24 小时；清理积压超过两个清理周期。
- metrics 禁止文件名、路径、配对码、设备名、公钥、IP 高基数明文 label。

## 速率限制与保留

- 保留代码内的配对来源/代码/设备限制、WebSocket 认证 freshness 与 replay 防护。
- 在边缘代理增加按来源的连接和请求上限，但不得绕过应用层设备签名授权。
- pairing/challenge/replay 行按代码 TTL 清理；短期失败计数仅保留防滥用窗口。
- 服务日志和 metrics 保留不超过 14 天；数据库备份按组织策略加密、限权和定期销毁。
- 信任与撤销状态属于授权控制面，不能按日志保留策略误删。

## 客户端更新

1. 从干净 commit 构建 Release，嵌入正确生产 WSS URL。签名输出应放在非文件同步目录：
   `MACCHANNEL_BUILD_CONFIGURATION=release MACCHANNEL_CODESIGN_IDENTITY="Developer ID Application: …"
   MACCHANNEL_APP_OUTPUT=/tmp/MacChannel.app bash Scripts/build-app.sh`。
2. 构建器会从内到外签名嵌入 framework、主程序和 app，并启用 hardened runtime 与可信时间戳；
   运行 `Scripts/test-release-signing.sh` 和 `codesign --verify --deep --strict` 验证。
3. 上传 Apple 公证、等待成功并 staple；运行 `codesign --verify --deep --strict`、
   `spctl --assess --type execute` 和 `stapler validate`。
4. 在 macOS 14 及当前支持版本验证升级保留 identity、trust、设置、历史和续传状态。
5. 发布 SHA-256、版本、commit 和签名 Team ID；通过受控下载渠道分发。

## 回滚

触发条件包括认证失败激增、错误信任传播、数据损坏、隐私命中、relay 不可用或客户端崩溃。

1. 停止扩大客户端发布；保留证据但先脱敏。
2. 将 rendezvous/coturn 流量切回上一不可变镜像 digest。
3. 若新迁移与旧服务兼容，保留数据库；否则隔离写流量，从发布前快照恢复新实例后切换。
4. 恢复上一版已签名、公证客户端；不要降级或覆盖设备私钥/信任数据库。
5. 若 secret 可能泄漏，先轮换 secret，再恢复服务；吊销受影响证书。
6. 运行健康、配对、direct、forced TURN、撤销和隐私检查。
7. 记录影响窗口、版本/digest、恢复点和后续修复；未通过验收前不重新推进。

## 当前发布阻塞

- 本机缺少 Docker，完整服务栈与 forced TURN 尚未运行。
- 没有两/三台实机验收证据。
- 当前主机的 Developer ID Application 签名、hardened runtime、可信时间戳和 strict verify
  已通过；但没有 notarytool 凭据。公证、staple 与最终 Gatekeeper 验收仍为 BLOCKED / NOT RUN。
