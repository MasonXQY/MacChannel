# MacChannel 个人网络真机验收

发布状态：**NOT RUN**。本表只能填写两台或三台真实 Mac 的实际观察，不得根据自动化测试、
网络拓扑或预期路线预填。所有证据 ID 必须是不透明编号，禁止写入 IP、MagicDNS/主机名、
配对码、指纹、文件名、路径或原始 Tailscale 输出。

两台 Mac 必须安装同一个 DMG（同一清单 SHA 和 commit），运行 macOS 14 或更高版本，并登录
同一个 Tailscale Personal tailnet。Mac C 只用于单目标和撤销检查。

| ID | 验收项目 | 必须观察的结果 | 状态 |
| --- | --- | --- | --- |
| RM-01 | Mac A/B 安装 | 同一 Developer ID 签名 DMG 可复制到应用程序并启动 | NOT RUN |
| RM-02 | 两个外部网络 | A/B 分处两个非同一路由器网络且都显示 Tailscale 已连接 | NOT RUN |
| RM-03 | Serve | 两端 51337 精确映射到 127.0.0.1:51338，无覆盖其他 Serve | NOT RUN |
| RM-04 | 双边配对 | 六位码与双方指纹人工确认后才建立信任 | NOT RUN |
| RM-05 | 重启信任 | 两端退出并重新打开后信任仍在且身份未变化 | NOT RUN |
| RM-06 | 菜单栏文件拖放 | 拖到图标、选择唯一目标、松手发送 | NOT RUN |
| RM-07 | 菜单栏目录拖放 | 目录层级和内容完整，同名不覆盖 | NOT RUN |
| RM-08 | SHA-256 | 发送端与接收端测试内容哈希一致 | NOT RUN |
| RM-09 | 直连路线 | UI/脱敏证据明确报告 direct，不按拓扑猜测 | NOT RUN |
| RM-10 | 中继路线 | 官方 Tailscale 状态与 UI 明确报告 relay 或 peer-relay | NOT RUN |
| RM-11 | 64 MiB 恢复 | 真实断网后同 TransferID 恢复且非空 ResumeMap | NOT RUN |
| RM-12 | 1 GiB 恢复与内存 | 中继路径恢复成功，峰值 RSS 小于 256 MiB | NOT RUN |
| RM-13 | Mac C 单目标 | 三台在线时发送给 B，C 未收到任何文件 | NOT RUN |
| RM-14 | 撤销 | 撤销后活跃连接关闭，新连接失败 | NOT RUN |
| RM-15 | 覆盖升级 | 新版本替换 app，Application Support、钥匙串、信任、设置和历史保留 | NOT RUN |

## 每台 Mac 的操作

1. 运行 `Scripts/accept-personal-mesh.sh --initialize A acceptance-A.json`（B/C 使用对应角色）。
2. 每完成一行，仅用脱敏证据 ID 记录，例如：
   `Scripts/accept-personal-mesh.sh --record acceptance-A.json RM-09 PASS E-RUN-0001 direct`。
3. 用 `--validate-only` 检查每个 JSON。只有 A/B 必需行和 C 相关行都有真实证据后，才能把
   本表对应状态从 `NOT RUN` 改为 `PASS` 或 `FAIL`。

未公证的内部签名版本首次打开只能使用 Finder 右键“打开”进行一次确认。不得执行
`spctl --master-disable`、`csrutil disable` 或删除 quarantine 来绕过系统整体安全设置。
