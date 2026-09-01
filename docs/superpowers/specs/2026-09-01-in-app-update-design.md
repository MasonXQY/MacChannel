# Mac 通道应用内更新设计

日期：2026-09-01  
状态：用户已批准
目标平台：macOS 14 或更高版本

## 1. 目标

让普通用户无需寻找下载页面即可确认当前版本、检查新版并安全完成升级。默认每天在后台检查一次，但必须由用户明确点击安装；任何自动检查都不得打断文件传输或强制退出应用。

成功标准：

1. 设置页始终显示当前短版本号和构建号，例如“Mac 通道 1.2.0（13）”。
2. 用户可在设置页点击“检查更新”，并明确看到“正在检查”“已是最新版”“发现新版”或可重试错误。
3. 每 24 小时最多自动检查一次。无更新或暂时离线时不弹窗打扰。
4. 发现新版后，菜单栏入口和设置页都提供可见提示；用户可查看中文发布说明并点击“下载并安装”。
5. 正在传输时可以下载更新，但重新启动必须延后到全部传输进入终态；用户也可取消安装。
6. 安装后原有身份、配对、设置、历史和未完成传输数据保持不变。
7. 被篡改、未正确签名、未公证、版本倒退或来源不符合配置的包必须拒绝安装。

## 2. 采用方案

使用 Sparkle 2 的 `SPUStandardUpdaterController`，固定到经过审查的明确版本，首版采用 2.9.6。Sparkle 负责调度检查、下载、更新包验证、原子替换和重新启动；Mac 通道只维护很薄的状态适配层，不自行实现安装器。

未采用的方案：

- 自制 GitHub 更新器：需要自行承担授权、应用替换、失败回滚和签名验证，安全面过大。
- 只跳转浏览器下载：不能满足应用内升级目标。

Sparkle 官方建议普通应用使用标准更新控制器，定时检查默认由框架调度；发布工具会为更新包生成 EdDSA 签名。参考：

- https://sparkle-project.org/documentation/programmatic-setup/
- https://sparkle-project.org/documentation/publishing/
- https://sparkle-project.org/documentation/security-and-reliability/

## 3. 用户体验

### 3.1 设置页

在设置页现有内容底部增加“软件更新”区：

- 第一行：`Mac 通道 1.2.0（13）`。
- 第二行：状态文字。空闲时显示最近检查时间；检查中显示“正在检查更新…”；失败显示简短原因和“重试”。
- 右侧主按钮：默认“检查更新”；发现新版后为“查看更新”。
- 辅助说明：“每天自动检查一次，是否安装由你决定。”

按钮使用现有 macOS 控件、键盘焦点和 VoiceOver 标签，不创建自定义网页式界面。版本值直接读取主应用 Bundle，读不到时显示“版本未知”，不得写死在 SwiftUI 源码中。

### 3.2 后台发现新版

自动检查发现新版时不抢占当前窗口：

- 菜单栏图标显示一个克制的更新提示状态。
- 菜单中“设置”附近增加“有新版本可用”。
- 打开设置页后显示新版版本号与“查看更新”。

用户点击“查看更新”后使用 Sparkle 标准更新窗口展示版本、中文发布说明、下载进度和安装按钮。用户关闭窗口或选择稍后处理时保持当前版本继续运行。

### 3.3 传输中的升级

下载不影响现有传输。用户点击安装时：

- 若没有进行中的传输，立即安装并重新启动。
- 若有进行中的传输，显示“将在传输完成后安装”，通过 Sparkle 的延迟重新启动回调等待活动传输归零，再继续安装。
- 若传输长时间未完成，应用不替用户取消传输；用户可回到更新窗口取消本次安装。
- 应用正常退出时，已下载且已验证的更新可按 Sparkle 的标准策略安装，但不得绕过活动传输保护。

## 4. 组件与数据流

### 4.1 UpdateController

新增一个主线程拥有的 `UpdateController`：

- 生命周期与应用代理一致，只创建一个 `SPUStandardUpdaterController`。
- 暴露当前版本、是否可检查、检查阶段、可用版本和用户可读错误。
- 提供 `checkForUpdates()`，只用于用户主动检查；后台检查交给 Sparkle 的 24 小时调度器。
- 实现必要的 Sparkle delegate，把“找到更新、未找到、失败、已下载、准备安装”转换为应用状态。
- 通过依赖注入把只读状态和动作传给设置界面，便于无网络单元测试。

### 4.2 传输门禁

`UpdateController` 接收一个只读的“当前是否存在活动传输”提供者，并订阅现有传输快照。需要重新启动时，若仍有活动传输，就保存 Sparkle 提供的一次性安装回调；活动数变为零时在主线程调用并清空。应用退出或用户取消时清除回调，防止重复执行。

### 4.3 设置与菜单栏

`SettingsSurfaceModel` 组合更新状态，但不直接依赖 Sparkle。`SettingsView` 只负责展示和触发动作。`StatusItemController` 只接收一个布尔值决定是否显示更新提示，不解析版本或访问网络。

数据流：

1. Sparkle 按计划读取 appcast。
2. 更新代理产生领域无关的展示状态。
3. 设置页和菜单栏观察同一状态。
4. 用户开始更新后由 Sparkle下载、验证和准备安装。
5. 更新控制器检查活动传输，满足条件后允许原子替换并重新启动。

## 5. 更新源与发布格式

固定更新源：

`https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml`

每个带自动更新能力的正式 GitHub Release 必须同时发布三个资产：

- `MacChannel.dmg`
- `MacChannel.manifest.json`
- `appcast.xml`

中文 Markdown 发布说明保存在仓库的发布目录中，并由 `generate_appcast` 以签名内容嵌入 `appcast.xml`，不作为第四个公开资产。

应用 Info.plist 增加：

- `SUFeedURL`
- `SUPublicEDKey`
- `SUEnableAutomaticChecks = true`
- `SUScheduledCheckInterval = 86400`
- `SUAutomaticallyUpdate = false`
- `SUAllowsAutomaticUpdates = false`
- `SUVerifyUpdateBeforeExtraction = true`
- `SURequireSignedFeed = true`

构建号 `CFBundleVersion` 严格递增，Sparkle 以它比较更新；短版本号只用于用户显示。

### 5.1 首次迁移

v1.1.10 本身没有更新器，因此不能远程获得本功能。包含更新器的首个正式版本定为 v1.2.0；两台 Mac 需要最后一次手动用公证 DMG 覆盖安装。自 v1.2.0 起，后续版本才通过应用内更新完成。设置、身份和配对数据位于应用包之外，覆盖安装不得改动这些数据。

## 6. 信任与密钥

更新同时依赖两套独立信任：

1. Apple Developer ID 签名、公证和 Gatekeeper 验证。
2. Sparkle Ed25519 更新包签名；启用签名 appcast 后，更新清单和发布说明也必须经过验证。

Sparkle 2.9.6 对应用更新采用官方双认证策略：有效的 Ed25519 archive 签名或与宿主匹配的代码签名身份任一成立即可继续，因此有效 Ed25519 更新允许轮换 Developer ID。MacChannel 不 fork 或弱化这一运行时策略。

作为发布侧补强，仓库提交 `Distribution/ProductionSigningAnchor.plist` 作为独立生产信任锚；权威值固定为 bundle ID `com.mason.macchannel`、Team ID `XKAZ67HN45`，designated requirement 使用 bundle ID 与 Team ID 约束而不固定叶证书，从而允许同 Team 证书轮换。`build-distribution.sh` 和 `build-update-feed.sh` 必须把候选 App/DMG 与该锚直接比较，并在 appcast 签名或发布前失败关闭。manifest 中的 Team ID 和 designated requirement 仅记录实际观察值用于审计，绝不能作为候选自身的信任依据。错误 Team/requirement 时必须在访问 Sparkle 私钥之前失败，并清理正式及 pending feed 输出。

Sparkle 私钥只保存于发布机钥匙串，不写入仓库、环境文件、CI 日志或 GitHub Release。公钥编入应用。发布脚本通过 Sparkle 官方 `generate_appcast`/`sign_update` 工具访问钥匙串生成签名，禁止把私钥作为命令行参数传入。

依赖版本在 `Package.swift` 中精确固定。升级 Sparkle 必须单独审查发布说明，至少关注安全修复、安装权限和无 Dock 菜单栏应用的行为。

## 7. 错误处理

- 后台检查网络失败：记录匿名错误类别，不显示弹窗；下个周期重试。
- 手动检查网络失败：显示“暂时无法检查更新，请稍后重试”。
- 已是最新版：明确显示当前版本已是最新版，并保留最近检查时间。
- appcast 签名、包签名或版本验证失败：拒绝更新，显示“更新无法通过安全验证”，不得提供绕过按钮。
- 下载中断：由 Sparkle 恢复或重新下载；当前应用继续可用。
- 安装授权被取消：保留当前应用，状态回到可检查。
- 更新后首次启动失败：分发产物保留上一正式版本的公开下载链接；不得删除用户数据或自动降级数据格式。

日志禁止记录发布说明正文、用户文件、路径、设备名、配对信息或密钥，只记录更新阶段、版本、构建号和稳定错误类别。

## 8. 测试与验收

### 8.1 自动化测试

- 版本展示从测试 Bundle 元数据正确生成，并覆盖缺失字段。
- 手动检查状态：空闲、检查中、最新、发现新版、失败。
- 自动检查失败不弹窗，手动失败有可重试提示。
- 活动传输存在时安装回调不会执行；最后一个活动传输结束后只执行一次。
- 菜单栏更新提示和设置状态同步，VoiceOver 文案可读。
- 构建脚本验证 Sparkle framework、XPC 服务、Info.plist 更新键和双架构签名。
- 发布脚本在缺少签名、公证、appcast 或版本/构建号不递增时失败关闭，不发布半成品。

### 8.2 真实升级验收

建立一个仅用于验收的独立 bundle ID、独立 feed URL 和已签名测试 appcast，完成以下路径。所有 fixture 的 dist、App、DMG、密钥、证书、日志、HOME/defaults 和 server root 都必须位于唯一、owner-only、可规范化验证的临时根；测试不得读写仓库正式 `dist/`、`/Applications/MacChannel.app`、正式 feed、正式 Sparkle 私钥、真实配对或历史：

1. 在两台 Mac 安装包含更新器的旧测试构建。
2. 后台检查在无更新时不打扰；手动检查明确显示最新版。
3. 发布构建号更高的已签名、公证测试包，两台 Mac 均能发现更新。
4. 一台空闲安装；另一台在真实文件传输过程中下载并点击安装，确认直到传输完成才重启。
5. 重启后核对新版本、原设备身份、双向信任、设置、历史和接收目录。
6. 使用被修改的 feed、被修改的 DMG、无法由代码签名身份补救的错误 Ed25519 key、错误 signer 加无效 Ed25519、较低构建号和离线网络分别验证拒绝或可恢复提示。另记录“有效 Ed25519 + 轮换 signer”按 Sparkle 官方策略被接受的 characterization，不得标成拒绝。
7. 发布时用错误 Team ID/designated requirement 的 DMG 验证在 appcast 生成前失败且两个 feed 输出都被清理；同 Team ID/designated requirement 必须通过。
8. 从公开 GitHub Release 重新下载最终资产，核对 appcast、SHA-256、Apple 公证票据和 Gatekeeper，再执行一轮真实升级。

本机自动化 fixture 必须走实际打包的 Sparkle updater，并使用进程内证书摘要与 `localhost` hostname 双重 pin。非 HTTPS、非本机 URL、外部重定向、外部 enclosure 和外部 release notes 均不得产生外网请求。每个拒绝案例必须断言实际的 sanitized nested error chain，并证明 build 13 的签名、Team/requirement、payload digest、Sparkle load 和 App launch 仍有效；接受案例对 build 14 做同等后置检查。server、updater、helper 和后代进程使用独立进程组与有界 TERM/KILL/reap，任何新残留进程都阻止继续。

只有第 8 步成功后，才能把应用内更新标记为可公开使用。

## 9. 本次范围外

- 静默强制安装。
- 企业 MDM 更新通道。
- 测试版/正式版多频道选择。
- 自建更新 CDN、差分包优化或更新遥测。
- 允许用户关闭更新包安全验证。
