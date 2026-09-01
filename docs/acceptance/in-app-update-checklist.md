# MacChannel 应用内更新验收表

本表用于 Task 8 的两台真实 Mac 最终验收。自动化本机 fixture 不能替代签名、公证、公开 Release 和真实双机升级；未现场执行的项目统一保留 `NOT RUN`。

## 版本与资产

| 项目 | Mac A | Mac B |
| --- | --- | --- |
| Mac 型号 | NOT RUN | NOT RUN |
| macOS | NOT RUN | NOT RUN |
| 旧版本 / build | NOT RUN | NOT RUN |
| 新版本 / build | NOT RUN | NOT RUN |
| Git commit | NOT RUN | NOT RUN |
| appcast SHA-256 | NOT RUN | NOT RUN |
| DMG SHA-256 | NOT RUN | NOT RUN |
| Team ID | NOT RUN | NOT RUN |
| designated requirement | NOT RUN | NOT RUN |
| 公证 / stapler / Gatekeeper | NOT RUN | NOT RUN |

## 正向升级

| 检查项 | Mac A | Mac B |
| --- | --- | --- |
| 空闲时发现、下载、验证、安装和一次重启 | NOT RUN | NOT RUN |
| 传输中安装延迟到传输结束 | NOT RUN | NOT RUN |
| 传输文件 SHA-256 一致 | NOT RUN | NOT RUN |
| 设备身份、双向信任与配对保留 | NOT RUN | NOT RUN |
| 设置、历史和接收目录保留 | NOT RUN | NOT RUN |

## 安全与恢复负例

| 场景 | 期望 | 现场结果 |
| --- | --- | --- |
| signed feed 被篡改 | Sparkle 拒绝，无绕过 | NOT RUN |
| DMG 被篡改 | Sparkle 拒绝，无绕过 | NOT RUN |
| 错误 Ed25519 key，且代码签名身份不认证 | Sparkle 拒绝 | NOT RUN |
| 错误 signer 加无效 Ed25519 | Sparkle 拒绝 | NOT RUN |
| 降级 payload | Sparkle 拒绝，旧 App 保持可用 | NOT RUN |
| 离线后重试 | 离线稳定，恢复网络后成功 | NOT RUN |
| 有效 Ed25519 加 signer 轮换 | 按 Sparkle 2.9.6 官方双认证策略接受，仅作 characterization | NOT RUN |
| 发布包 Team ID / designated requirement 不匹配 | appcast 发布前失败且两个 feed 输出清理 | NOT RUN |

## 最终发布复核

| 检查项 | 结果 |
| --- | --- |
| 从公开 GitHub Release 重新下载 DMG、manifest、appcast | NOT RUN |
| 三资产版本、build、URL、digest 与签名一致 | NOT RUN |
| 两台 Mac 均从应用内完成最终公开版本升级 | NOT RUN |
| 验收人、时间与备注 | NOT RUN |
