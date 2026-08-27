# Mac 通道隐私审计

审计日期：2026-08-27
被审计代码 commit：`cf75945`
静态证据时间（UTC）：`2026-08-27T13:06:57Z`
静态审计脚本 SHA-256：

- `audit-privacy.sh`: `aa4c70130f58048b558b672c42541d24611f16dde057b750b64e0c3afa8b7800`
- `check-sensitive-logging.sh`: `09a7c7935f6733d84aca65f517c72c078c078a5bc5c5d0a7f54a869e72b11b02`
- `test-privacy-audit.sh`: `7a86abbe6c8f250f5019ba3e728d1871b909bb3e7020183b29d8dd5e329cbfff`
- `test-privacy-runtime-block.sh`: `e3d85180c703925f101da51f2ba1ae7634bf005b76de226912bd9f77614f09fd`

审计文档 commit：见本文件末尾“不可变文档版本”；首次提交后单独追加，避免自引用哈希。
总体状态：**PARTIAL / 运行中服务审计 BLOCKED**

## 隐私合同

- 设备私钥只存在客户端设备专属钥匙串，不上传。
- rendezvous、coturn、PostgreSQL 和 metrics 不得包含明文文件名、目录结构、完整路径、
  文件内容、六位配对码、设备私钥或本地传输历史。
- 信令服务只能看到认证设备标识、连接元数据和不透明信令/加密握手载荷。
- TURN 只转发加密流量，不得拥有可写持久文件卷。
- 本地历史可含文件显示名与最终路径，但不得上传。

## 本机完成的证据

| 检查 | 方法 | 结果 | 边界 |
| --- | --- | --- | --- |
| 仓库敏感日志扫描 | `bash Scripts/audit-privacy.sh --static-only` | STATIC PASS | 静态源码/配置，不等于运行时日志 |
| 数据库 schema 列检查 | 扫描 `Services/migrations/*.sql` | PASS | 未发现 filename、filepath、content、private_key 或 transfer_history 列 |
| TURN 文件持久化 | 检查 Compose 的 coturn 服务与配置 | PASS | coturn 只有只读 secret 输入和 tmpfs；无可写持久 volume；配置将日志丢弃到 `/dev/null` 并禁用 stdout/用户名日志 |
| 客户端日志调用 | 扫描生产 Swift 源码的 `print`、`NSLog`、Logger/OSLog | PASS | 未发现把路径、文件名、内容、配对码或私钥写入日志的生产调用 |
| 服务日志调用 | 扫描生产 Go 源码 | PASS | 日志只记录启动/关闭、固定错误类别；未记录请求体、信令 payload、配对码或凭据 |
| 私钥上传面 | 检查身份 API 与网络信封 | PASS | 网络使用公钥和签名；`DeviceIdentity` 不暴露私钥字节 |
| 配对存储期限合同 | schema expiry 索引与 Go 过期/清理测试 | PASS | 静态合同和自动化测试证据；未在本机 PostgreSQL 17 运行观察 |

静态脚本检查禁止的服务端持久化字段、生产 Swift/Go/shell 日志 sink 与敏感变量组合、
以及 TURN mount/日志合同。`Scripts/test-privacy-audit.sh` 注入三个源码 mutant；至少
`log.Printf("payload=%s", payload)`、Swift 路径插值和 shell 私钥变量输出必须被拒绝。
固定、无敏感参数的状态类别日志使用精确 allowlist，避免把 `stack-secrets` 这样的固定
组件名误报为 secret 值。该扫描不是完整语法分析器，也不声称覆盖运行时动态生成日志。

## 尚未执行的运行时审计

本机没有 Docker，因此以下项目均为 **BLOCKED / NOT RUN**：

| ID | 运行时检查 | 必须收集的证据 | 状态 |
| --- | --- | --- | --- |
| PA-01 | 用唯一名称 fixture 完成 direct 与 TURN 传输后扫描 rendezvous stdout | 脱敏日志和 fixture 零命中 | BLOCKED |
| PA-02 | 扫描 coturn stdout 与认证错误路径 | 零文件名/路径/内容/配对码/用户名/私钥命中 | BLOCKED |
| PA-03 | 查询 PostgreSQL schema 与所有文本/bytea 可识别元数据 | 表清单、列清单、fixture 零命中 | BLOCKED |
| PA-04 | 抓取 Prometheus metrics | metric 名称/label 清单，fixture 与设备可识别值零命中 | BLOCKED |
| PA-05 | 等待配对与 replay TTL 后查询过期行 | 过期前后计数、UTC 时间和 SQL 证据 | BLOCKED |
| PA-06 | 检查容器 mount 和写层 | `docker inspect` 脱敏输出；coturn 无持久可写卷 | BLOCKED |

在 Docker 主机上运行 `bash Scripts/verify-e2e.sh` 后，使用同一唯一 fixture 执行
PA-01 至 PA-06。任一敏感值命中均为发布阻断问题，不能通过脱敏 waiver 关闭。

未来运行时 producer/bundle 的最低规范见 `privacy-evidence-schema.md`，其状态明确为
**NOT IMPLEMENTED**。当前仓库不读取、验签或判断任何运行时 evidence；这样可以避免
任意自签名 bundle 或人工 JSON 自证。`audit-privacy.sh` 只有 `--static-only` 能返回 0。
无参数或任何其他参数都会完成静态检查后稳定返回状态 2 和 `RUNTIME BLOCKED`，且不会
访问传入路径、不可读文件或符号链接。

## 数据最小化与保留

- 配对会话、挑战、重放 nonce 和失败计数都有明确 expiry 字段与索引；服务清理器负责删除。
- 已确认的信任/撤销记录是安全授权状态，不按短期 pairing TTL 删除。
- rendezvous 不建文件、路径、内容或传输历史表。
- TURN 凭据最长十分钟，仅在内存和客户端连接配置中使用。
- 应用本地失败 staging 最长保留七天用于恢复；用户取消或完成后按状态安全清理。
- 生产日志与 metrics 的保留期必须在部署环境设为 14 天或更短，且禁止高基数设备 ID label。

## 结论

仓库静态隐私边界在本机检查范围内未发现未解决问题。由于 PA-01 至 PA-06 未运行，
隐私审计不能标记为完成，也不能据此批准生产发布。

## 不可变文档版本

包含审计脚本、静态证据哈希和本修订正文的不可变提交为 `764e280`。本行由后续仅追加
提交记录，不改变该提交中被审计的内容。

`5158d40` 曾加入未具备可信 producer 的运行时 verifier；最终收敛提交已删除该 PASS
路径。该历史提交不得用作验收门禁。

`0ba4bb2` 增加未来 producer schema；最终收敛提交把它明确标记为 NOT IMPLEMENTED。

删除未受信运行时 PASS 路径、删除旧 evidence scanner，并以状态 2 固定运行时门禁的不可变
内容提交为 `f506df56866dcb6dc518cd6153006a66aa2a49ae`。本行由后续仅追加提交记录。
