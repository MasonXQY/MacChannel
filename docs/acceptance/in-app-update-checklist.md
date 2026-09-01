# MacChannel 应用内更新验收表

本表用于 Task 8 的两台真实 Mac 最终验收。自动化本机 fixture 不能替代签名、公证、公开 Release 和真实双机升级；未现场执行的项目统一保留 `NOT RUN`。

## 已自动验证的公开发布证据

以下证据于 2026-09-02（Asia/Dubai）从无凭据的公开 GitHub Release URL 下载后验证。它只证明公开资产、签名与公证状态，不替代 Mac A / Mac B 的现场升级。

| 项目 | 自动验证结果 |
| --- | --- |
| Release | [v1.2.0](https://github.com/MasonXQY/MacChannel/releases/tag/v1.2.0)，非草稿、非预发布，恰好包含 `MacChannel.dmg`、`MacChannel.manifest.json`、`appcast.xml` |
| 发布 commit / annotated tag | `657fce2302b781c8b11e2a529736f80bda067545`；远端 `v1.2.0^{}` 指向该 commit |
| 版本 / build | `1.2.0 (13)`；manifest、appcast 和挂载 App 一致 |
| `MacChannel.dmg` SHA-256 | `89d97360142c9fdc75f3ad09a722f9108abb4081276ba75406e0d2a7fb4eed9e` |
| `MacChannel.manifest.json` SHA-256 | `6e843ab3c5fe9fa1d6c081aefb122d76a0436894e1fafda60f81876be68cff08` |
| `appcast.xml` SHA-256 | `2014db28f1aae3010267255676e33619f9ec4ab52eee9a4472b155ae6b834912` |
| appcast enclosure | `https://github.com/MasonXQY/MacChannel/releases/download/v1.2.0/MacChannel.dmg`；版本、build、长度与公开 DMG 一致，Ed25519 signature 字段存在 |
| Bundle / Team / designated requirement | `com.mason.macchannel` / `XKAZ67HN45`；挂载 App 通过 `Distribution/ProductionSigningAnchor.plist` 的 Developer ID Application requirement |
| 签名与公证 | DMG 与嵌套 App 通过 strict code-sign；`stapler validate` 成功；DMG 与 App 均获 Gatekeeper `accepted`，来源为 `Notarized Developer ID` |

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
| manifest 与错误候选 Team/requirement 自洽 | 仍按独立生产锚拒绝，且私钥未访问 | NOT RUN |
| 同 Team ID 但 Apple Development 证书 | Developer ID Application 类别锚拒绝，且私钥未访问 | NOT RUN |
| 缺失、畸形或错误 TLS pin / hostname 不匹配 | 进程内拒绝，不访问外部网络，旧 App 可用 | NOT RUN |

## 最终发布复核

| 检查项 | 结果 |
| --- | --- |
| 从公开 GitHub Release 重新下载 DMG、manifest、appcast | PASS（2026-09-02，无凭据公开 URL，全新 owner-only trusted temp） |
| 三资产版本、build、URL、digest 与签名一致 | PASS（见“已自动验证的公开发布证据”） |
| 两台 Mac 均从应用内完成最终公开版本升级 | NOT RUN |
| 验收人、时间与备注 | NOT RUN |

发布复核时以 `Distribution/ProductionSigningAnchor.plist` 的 production bundle ID、Team ID、Developer ID Application certificate-class OID 与轮换兼容 requirement 为权威；manifest 只记录候选包的观察值。Task 7 的隔离本机自动化只证明本地打包 updater、拒绝/恢复和发布门禁；上表的 Task 8 自动化证据证明本次公证与公开 Release。Mac A / Mac B 的安装、升级、传输延迟重启及状态保留仍未现场执行，所有对应项目继续保持 `NOT RUN`。
