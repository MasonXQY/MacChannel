# Mac 通道真实 Mac 验收记录

状态：**NOT RUN**
规则：所有行必须在相同 Git commit 的签名、公证构建上完成。不得用模拟器、单机
loopback、单元测试或 Docker 内部流量替代。失败必须重开对应实现任务，不接受 waiver。

## 测试批次

| 字段 | 实测值 |
| --- | --- |
| 验收日期与时区 | NOT RUN |
| 执行人 | NOT RUN |
| Git commit | NOT RUN |
| App 版本 / build | NOT RUN |
| Developer ID 签名身份 | NOT RUN |
| 公证 request ID / stapler 结果 | NOT RUN |
| Rendezvous 镜像 digest | NOT RUN |
| coturn 镜像 digest | NOT RUN |
| 服务部署环境 | NOT RUN |

## 设备清单

| 设备 | 型号 | macOS 版本 / build | CPU | 网络 | 安装 commit | 证据文件 |
| --- | --- | --- | --- | --- | --- | --- |
| Mac A | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Mac B | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Mac C | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

证据文件必须放在发布系统的受控附件区；仓库中只写相对证据 ID，不提交含设备名、
公网 IP、完整本地路径、配对码、密钥或未脱敏日志的材料。

## 验收矩阵

每行的“结果”只能填写 `PASS`、`FAIL` 或 `NOT RUN`。未执行时观察连接方式必须为
`NOT RUN`；执行后只能填写 `局域网直连`、`互联网直连`、`加密中继` 或 `不适用`。

| ID | 场景 | 日期 | 设备 / macOS / 型号 | 网络与故障注入 | Git commit | 观察连接方式 | 源 SHA-256 | 目标 SHA-256 | 耗时 | 中断点 | 恢复字节偏移 | 最终下载路径（脱敏） | 结果 | 证据文件 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RM-01 | 三设备配对：A 配 B，再加入 C；三方指纹人工核对 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | 不适用 | 不适用 | 不适用 | NOT RUN | NOT RUN |
| RM-02 | Finder 拖到菜单栏；显示“准备发送”；设备扇悬停并松手 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-03 | 同一 LAN 发送单文件 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-04 | 同一 LAN 发送含空目录、Unicode 名称的文件夹 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-05 | 两个不同外部网络，ICE 互联网直连 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-06 | 阻断直连后强制 TURN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-07 | 传输中断网并恢复，复用同一 TransferID | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| RM-08 | 1 GiB 文件：内存、速度、完整性和最终落盘 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| RM-09 | 全局与来源设备自定义下载目录 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-10 | 同名文件连续发送，产生编号且不覆盖 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-11 | 接收磁盘空间不足，预检失败且无最终文件 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | NOT RUN | 不适用 | 不适用 | NOT RUN | NOT RUN | NOT RUN |
| RM-12 | 撤销 B 后，B 无法建立新连接；A/C 状态收敛 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | 不适用 | 不适用 | 不适用 | NOT RUN | NOT RUN |
| RM-13 | 接收后从第一层菜单路径“菜单栏图标 → 刚刚收到 → 文件项”在 Finder 中显示；验证绿点、最近 5 项、逐项确认，以及“查看全部历史…”直接打开历史分段 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | 不适用 | 不适用 | NOT RUN | 不适用 | 不适用 | 不适用 | NOT RUN | NOT RUN |

## 每行执行要求

1. 记录开始前的 commit、客户端版本和三台设备时间。
2. 为传输行创建唯一文件名，在发送前后分别用 `shasum -a 256` 计算哈希。
3. 从应用界面记录实际 route；不要根据网络布置推测 route。
4. 续传行同时记录断开时已确认字节、恢复协商偏移和新连接流量。
5. 截图和日志先脱敏，再记录证据文件 ID；原始材料按发布组织的访问策略保存。
6. 每行结束后检查接收目录、临时目录、历史和第三台设备未被误投递。

## 完成判定

只有 RM-01 至 RM-13 全部为 `PASS`，且批次字段完整、哈希一致、证据可追溯，
真实 Mac 验收才可签字。当前状态为 **NOT RUN**。
