# Mac 通道隐私审计

审计日期：2026-08-27  
审计 commit：`cf75945` 加本文件所在提交前工作树  
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
| 仓库敏感日志扫描 | `bash Scripts/audit-privacy.sh` | PASS | 静态源码/配置，不等于运行时日志 |
| 数据库 schema 列检查 | 扫描 `Services/migrations/*.sql` | PASS | 未发现 filename、filepath、content、private_key 或 transfer_history 列 |
| TURN 文件持久化 | 检查 Compose 的 coturn 服务与配置 | PASS | coturn 只有只读 secret 输入和 tmpfs；无可写持久 volume；stdout 日志，用户名隐藏 |
| 客户端日志调用 | 扫描生产 Swift 源码的 `print`、`NSLog`、Logger/OSLog | PASS | 未发现把路径、文件名、内容、配对码或私钥写入日志的生产调用 |
| 服务日志调用 | 扫描生产 Go 源码 | PASS | 日志只记录启动/关闭、固定错误类别；未记录请求体、信令 payload、配对码或凭据 |
| 私钥上传面 | 检查身份 API 与网络信封 | PASS | 网络使用公钥和签名；`DeviceIdentity` 不暴露私钥字节 |
| 配对存储期限合同 | schema expiry 索引与 Go 过期/清理测试 | PASS | 静态合同和自动化测试证据；未在本机 PostgreSQL 17 运行观察 |

`Scripts/audit-privacy.sh` 使用一个运行时生成、不会写入仓库的唯一 fixture 标记，
检查 tracked 服务/配置/迁移文件不含该标记，并执行禁止字段、生产日志调用和 TURN
mount 合同检查。它是 fail-closed 的仓库审计，不声称发生了真实文件传输。

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
