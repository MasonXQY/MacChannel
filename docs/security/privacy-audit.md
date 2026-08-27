# Mac 通道隐私审计

审计日期：2026-08-27
被审计代码 commit：`cf75945`
静态证据时间（UTC）：`2026-08-27T12:54:46Z`
静态审计脚本 SHA-256：

- `audit-privacy.sh`: `6bdc32e3884f6df086b0436f30c3c121f4d60393c1defba0ccd217e1a5472d9e`
- `check-sensitive-logging.sh`: `09a7c7935f6733d84aca65f517c72c078c078a5bc5c5d0a7f54a869e72b11b02`
- `test-privacy-audit.sh`: `f2665537b47b549dfa0907f00382f12bee27b35d0be8df88003c1b0db5f492e6`
- `scan-privacy-evidence.sh`: `8ddc121bdc09fb66942b6dfa4f493d39ad78bbc55c83fe9084b50161837d54eb`

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

运行时 fixture 必须先真实发送。使用独立、随机、16 至 128 字符 ASCII canary；content
canary 必须实际写入文件，filename/path canary 必须实际进入源名称/路径。证据不得把
fixture 全文放入命令行。证据目录必须含签名 `manifest.json`、传输 `receipt.json`、
canary 分类文件、源/目标回执、限定时间窗的 client/rendezvous/coturn 原始日志、
PostgreSQL 查询前后 JSON、`docker compose ps`、原始 `docker inspect`/mount JSON 与
metrics 快照。manifest 绑定 code commit、canary ID、TransferID、源/目标 SHA-256、
起止 UTC、实际容器 ID 和日志捕获边界。
完整 producer/bundle 合同见 `privacy-evidence-schema.md`。当前 `verify-e2e` 尚未实现该
可信 producer，且独立审计公钥尚未配置，所以运行时状态保持 BLOCKED。

```sh
bash Scripts/audit-privacy.sh \
  --runtime-evidence /受控证据目录 \
  --fixture-file /实际发送的唯一fixture
```

无参数运行只会输出 `STATIC PASS`，随后以状态 2 输出 `RUNTIME BLOCKED`。运行时校验
还要求仓库固定、由独立审计方控制的 `Infrastructure/privacy-auditor-public-key.pem`，
并验证 manifest 签名；当前没有该 key，因此任何自建 evidence 都不能得到 PASS。
签名通过后，门禁会把 manifest 与 receipt、实际 fixture/destination hash、当前 live
container ID、inspect/mount JSON、查询时间窗和过期行计数交叉核对。

证据内容扫描为每类使用独立 canary：filename、path、content、pairing code、private key
和 TURN username。扫描兼容二进制并删除换行后复查，可捕获跨行拆分 canary；单个原始
输出上限 16 MiB。命中时只报告类别与脱敏相对证据文件名，使用 quiet search，绝不
输出匹配行或 canary。配对码、TURN username 和尤其私钥必须来自真实受控采集；无法
安全取得真实私钥时，该分类保持 NOT RUN/BLOCKED，不能用任意 token 自报 PASS。

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

消除运行时自证、加入签名 manifest/raw evidence 交叉校验、二进制/跨行/大文件与敏感
类别 mutant 的不可变内容提交为 `5158d40`。本行同样由后续仅追加提交记录。
