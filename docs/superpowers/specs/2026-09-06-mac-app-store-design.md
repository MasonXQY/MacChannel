# DropMesh 1.3.0 Mac App Store 上架设计

日期：2026-09-06  
目标版本：DropMesh 1.3.0  
状态：产品范围、构建隔离、沙盒、审核材料和发布门禁已确认，等待书面规格审核

## 1. 背景与决定

DropMesh 1.2.6 通过官网/GitHub Release 分发 Developer ID 签名、公证并装订的 DMG，使用
Sparkle 提供应用内更新。该版本已投入使用，现有用户的身份、信任、设置、历史、未完成传输
和更新通道不能因为 Mac App Store 上架工作受到影响。

下一阶段暂停 Windows 开发，专注完成 Mac App Store 上架。仓库中已有的 Windows 设计和计划
只作为暂停记录保留，不属于本规格的实施范围，也不能触发 Windows 功能代码、构建或发布。

采用同一仓库、两个正式构建配置：

- `Direct`：现有官网版，继续使用原有 bundle ID、DMG、Developer ID、公证和 Sparkle；
- `AppStore`：新增商店版，使用 bundle ID `com.zensystech.dropmesh`、App Sandbox、App Store
  签名与商店更新，不包含 Sparkle。

两个构建共享传输核心和产品界面，仅在分发适配、数据容器、权限、更新器、签名和打包层分离。
App Store 首版免费、无订阅、无内购。

完成 AppStore 1.3.0 不会自动发布 Direct 1.3.0。官网公开通道继续停留在已验证的 1.2.6，
直到产品所有者单独批准 Direct 新版本；AppStore 构建或上传脚本无权修改该决定。

## 2. 目标与非目标

### 2.1 目标

1. 在 Mac App Store 发布功能完整的 DropMesh 1.3.0。
2. 保留菜单栏拖放、文件/文件夹、剪贴板、自动接收、通知、最近收到、断点续传、局域网直连、
   互联网直连和加密中继。
3. App Store 版与现有官网 1.2.6 能完成配对和双向传输。
4. App Store 版符合沙盒、文件访问、登录启动、更新、隐私、加密申报、签名和上传要求。
5. 官网版从同一提交构建时行为不退化，现有更新 Feed 不被商店发布流程覆盖。
6. 应用和商店资料提供简体中文与英文。

### 2.2 非目标

- 不实现 Windows、Linux、iOS、iPadOS 或 Android 客户端；
- 不把官网现有用户自动迁移到 App Store 版；
- 不修改配对、加密、传输帧、断点续传或服务端协议；
- 不为上架增加账户、订阅、广告、分析或跟踪；
- 不在 App Store 版中保留任何第三方自更新能力；
- 不把官网版整体改造成沙盒应用；
- 不要求现有官网用户卸载、重新配对或更换更新渠道。

## 3. 构建架构

### 3.1 编译期渠道

分发渠道是构建时常量 `direct` 或 `appStore`，不能由用户设置、环境变量或远端服务在运行时
切换。发布构建必须从签名资源读取渠道，并在测试中证明渠道、bundle ID、权限、更新器和包
格式一致。

共享部分：

- `MacChannelCore` 的身份、信任、发现、配对、连接、加密、传输、存储和恢复；
- 菜单栏、设备列表、配对、发送、接收、历史和设置的公共界面模型；
- Go rendezvous 服务、生产端点、TURN 和协议；
- 中英文术语和除渠道特有项以外的用户文案。

渠道适配部分：

- 版本更新服务；
- 数据目录与钥匙串命名空间；
- entitlement、provisioning profile 和签名身份；
- Info.plist 渠道字段和权限说明；
- DMG/Sparkle Feed 或 App Store `.pkg`；
- 渠道特有的验收和发布脚本。

### 3.2 更新器隔离

现有 UI 通过 `SoftwareUpdateServicing` 一类的窄接口获取版本状态和执行检查。实现拆为：

- Direct 适配器：当前 Sparkle 控制器，行为和 Feed 不变；
- AppStore 适配器：不下载或安装代码，只显示“更新由 Mac App Store 管理”，并可打开 DropMesh
  的 App Store 产品页。

App Store 构建的链接图、复制资源和最终 bundle 都不得包含：

- `Sparkle.framework`；
- `Downloader.xpc`、`Installer.xpc`、`Updater.app` 或 `Autoupdate`；
- `SUFeedURL`、`SUPublicEDKey` 或其他 Sparkle Info.plist 键；
- Sparkle 更新签名公钥、Feed URL、更新工具或对应可执行符号。

Direct 构建继续包含并验证当前 Sparkle 2.9.6；为商店拆分依赖时不得改变其签名顺序、Feed
安全检查或活动传输结束后安装的约束。

### 3.3 Bundle 和产品身份

| 项目 | Direct | AppStore |
| --- | --- | --- |
| 产品名 | DropMesh | DropMesh |
| Bundle ID | `com.mason.macchannel` | `com.zensystech.dropmesh` |
| 数据域 | 现有非沙盒 Application Support | 商店沙盒容器 |
| 钥匙串域 | 现有服务名 | 商店专用服务/访问组 |
| 更新 | Sparkle | Mac App Store |
| 发布包 | 公证 DMG | App Store `.pkg` |
| 价格 | 免费 | 免费 |

两个渠道的身份和数据明确隔离。从 Direct 切换到 AppStore 时需要重新配对；接收文件留在用户
选择的文件夹中，不由卸载或换渠道操作删除。应用和支持页要在安装前明确说明这一点。

## 4. App Sandbox 与系统权限

### 4.1 Entitlements

AppStore 主程序只申请以下沙盒权限：

- `com.apple.security.app-sandbox = true`；
- `com.apple.security.network.client = true`；
- `com.apple.security.network.server = true`；
- `com.apple.security.files.downloads.read-write = true`；
- `com.apple.security.files.user-selected.read-write = true`；
- 与 `com.zensystech.dropmesh` 对应的 application identifier 和钥匙串访问组。

不申请全磁盘访问、Apple Events、摄像头、麦克风、通讯录、位置、辅助功能、root 权限、动态
代码执行或临时沙盒例外。若实际功能必须新增 entitlement，停止上架候选并先更新本规格，
不能通过宽泛权限绕过沙盒问题。

Direct 构建保持当前 entitlement 和签名路径，不因为 AppStore 配置获得新权限或 provisioning
profile 依赖。

### 4.2 网络

网络客户端权限覆盖生产 WSS/HTTPS、STUN/TURN 和发起的 WebRTC 连接；网络服务端权限覆盖
Bonjour/mDNS、UDP 和传入连接。Info.plist 提供中英文的本地网络用途说明和 Bonjour 服务声明。

拒绝本地网络权限时：

- 应用仍能启动、查看设置、历史和已接收文件；
- 公网服务可用时继续显示经过认证的互联网在线状态；
- 局域网发现不可用时显示明确说明和系统设置入口；
- 不反复弹权限请求，也不建议用户关闭系统安全功能。

### 4.3 发送文件

Finder 拖入或文件选择器选中的项目通过用户选择权限访问。准备发送时立即验证路径、类型、
大小、符号链接和当前可读性，并复制/打包到商店沙盒管理的 Outgoing 区域。这样传输和断点
恢复不依赖临时的拖放授权在重启后仍然有效。

自定义来源位置只有在用户明确选择后才保存安全作用域书签。书签必须验证路径身份、处理过期
并在使用后配对调用 start/stop access；不能把普通绝对路径当作持久权限。

剪贴板文本和图片先转换为沙盒临时文件；复制的文件/文件夹遵循与 Finder 选择相同的授权和
打包流程。完成、失败或取消后按现有生命周期清理临时内容。

### 4.4 接收文件

默认目标为 `~/Downloads/DropMesh`，由 Downloads 读写 entitlement 授权。自定义目标必须由
用户通过系统目录选择器选取并保存安全作用域书签。

接收内容先写入沙盒容器的 staging 目录。只有分块认证、整体 SHA-256 和路径安全检查全部通过
后，才原子移动到最终目录。同名文件继续自动编号，未完成内容不能使用最终名称。

目录权限失效时暂停任务并提供“重新选择目录”；磁盘空间不足时保留可恢复状态并显示所需空间。
不能因为沙盒写入失败把任务显示为成功。

### 4.5 通知与登录启动

通知继续使用公开的 UserNotifications API，首次需要时请求授权。拒绝通知不影响接收，菜单栏
绿点和最近收到仍可用。

“登录时启动”默认关闭，只能由用户在设置中主动开启或关闭。继续使用公开的 `SMAppService`
能力，不安装 helper 到共享位置，不在用户退出 DropMesh 后留下未获同意的进程。

## 5. 运行时数据和渠道共存

### 5.1 商店数据

AppStore 的以下内容只保存在其沙盒容器或专用钥匙串域：

- 设备长期身份；
- 双向信任和撤销记录；
- 本机设置与接收策略；
- 传输历史、输出索引和恢复 journal；
- 未完成发送包和接收 staging；
- 安全作用域书签。

商店版不能直接读取 Direct 的 Application Support 或钥匙串条目，也不申请临时例外来静默
迁移。用户切换渠道时重新配对是明确的产品行为。

### 5.2 防止双实例冲突

AppStore 启动和运行期间使用公开的 `NSWorkspace`/`NSRunningApplication` 信息检查已知 Direct
bundle ID。发现官网版正在运行时，AppStore 不启动网络核心，并显示“另一个 DropMesh 版本
正在运行，请退出后重试”。它持续在进入前台、系统唤醒和网络核心启动前重新检查。

这项保护由 AppStore 单侧承担，避免要求已经发布的 Direct 1.2.6 改动。即使用户在 AppStore
运行后启动旧 Direct，AppStore 也会停止自己的广告、presence、监听和自动接收，只保留说明
界面。停止必须等待连接和文件句柄安全关闭，不能损坏进行中的文件。

## 6. 用户体验与本地化

AppStore 保留当前菜单栏产品形态，不增加常驻 Dock 图标。首次启动以小型说明页解释：

1. DropMesh 位于菜单栏；
2. 默认把收到的文件保存到 `Downloads/DropMesh`；
3. 首次使用局域网、通知和自定义目录时系统会请求权限；
4. 与另一台 Mac 配对需要六位码和一次允许；
5. 从官网版切换需要重新配对。

说明页不能阻止用户查看设置或退出应用，也不能预先请求与当前操作无关的权限。

AppStore 和 Direct 1.3.0 都包含简体中文与英文，默认跟随系统语言，并允许在设置中选择跟随
系统、简体中文或 English。所有菜单、通知、错误、权限说明、帮助、隐私入口和 App Store
更新文案都必须本地化；切换语言不重启网络核心或中断传输。

这里的 Direct 1.3.0 是同提交回归候选，不代表自动向官网用户发布。

除以下渠道差异外，两个版本的功能和界面一致：

- AppStore 显示“更新由 Mac App Store 管理”；
- Direct 显示现有 Sparkle 更新状态和操作；
- AppStore 设置中显示“App Store 版本”；Direct 显示“官网版本”；
- AppStore 在检测到 Direct 同时运行时显示渠道冲突说明。

## 7. 隐私、加密与审核材料

### 7.1 公开页面

使用 GitHub Pages 免费发布：

- 产品页：`https://masonxqy.github.io/MacChannel/`；
- 隐私政策：`https://masonxqy.github.io/MacChannel/privacy/`；
- 支持页：`https://masonxqy.github.io/MacChannel/support/`。

三个页面和应用内入口都提供简体中文与英文。隐私政策至少说明：

- 文件内容和文件清单的端到端加密边界；
- 服务端处理的设备标识、在线状态、信令、IP/网络信息和 TURN 用量；
- 每类数据的用途、保留时间、共享对象和删除方式；
- 本地身份、信任、设置、历史和接收文件的存储位置与删除方式；
- 不使用广告、跨应用跟踪或营销分析；
- 用户如何联系支持和请求删除服务端可删除的数据。

### 7.2 隐私审计与清单

提交前对客户端、WebRTC 二进制、Go 服务、反向代理、PostgreSQL、coturn、监控和生产日志做
一次从代码到线上配置的审计。App Store Connect 的 App Privacy 答案必须依据审计证据，不能
仅依据设计意图填写“未收集”。

在 AppStore 主 bundle 的 `Contents/Resources/PrivacyInfo.xcprivacy` 中声明真实的数据处理、
跟踪状态和适用 API；验证所有第三方 framework 的隐私清单位置、格式和签名。无效或缺失的
第三方清单必须通过升级、替换或移除依赖解决，不能手工伪造第三方声明。

### 7.3 加密出口合规

DropMesh 使用 TLS、WebRTC、P-256、HKDF、AES-GCM/现有应用层加密和端到端文件传输，因此
必须在 App Store Connect 如实完成加密问卷。根据问卷结果：

- 若属于免提交文件的标准加密，设置准确的 `ITSAppUsesNonExemptEncryption` 值并保存判断依据；
- 若需要文件或审批，在 App Store Connect 上传并获得批准后再关联构建；
- 不为了跳过问卷把实际使用加密的应用声明为“不使用加密”。

### 7.4 商店资料

App Store 产品记录使用名称 DropMesh；若该名称不可用，停止并让产品所有者选择新名称，不
自动更名。分类为“工具”，首版免费、无内购。

资料包含中英文副标题、说明、关键词、隐私政策、支持页面、营销 URL、版本说明、版权、年龄
分级问卷和各要求尺寸的真实截图。截图必须来自最终 AppStore 候选，不使用官网版或设计稿冒充。

审核备注提供：

- 无账户、无登录的说明；
- 两台 Mac 六位码配对步骤；
- 文件、文件夹和剪贴板发送步骤；
- 默认下载位置和通知行为；
- 局域网与异地连接说明；
- 审核期间可用的生产服务状态；
- 一段不公开索引的完整双 Mac 演示视频；
- 可以及时响应的审核联系信息。

## 8. 签名、打包与上传

### 8.1 账户材料

正式上传前需要在 Apple Developer 团队 `XKAZ67HN45` 下准备：

- 显式 App ID `com.zensystech.dropmesh`；
- 启用 App Sandbox 能力的 Mac App Store provisioning profile；
- Apple Distribution 或 Mac App Distribution 证书及本机私钥；
- Mac Installer Distribution 证书及本机私钥；
- App Store Connect 中的 macOS App 记录；
- 上传所需的 App Store Connect 权限或 API Key。

截至本规格撰写时，本机钥匙串只有 Apple Development 和 Developer ID Application 身份，
尚不具备正式 App Store 应用/安装包签名能力。开发和沙盒测试可以继续，但不能声称已经可以
上传正式包。

### 8.2 构建与包

AppStore 构建流程：

1. 从干净、已提交的 HEAD 进行 release 构建；
2. 生成商店专用 Info.plist、entitlements 和本地化资源；
3. 只复制 AppStore 允许的主程序、WebRTC framework 和资源；
4. 从最内层代码开始使用 App Store 分发身份和 provisioning profile 签名；
5. 验证 bundle ID、Team ID、entitlements、版本、构建号、架构、签名链和禁止内容；
6. 使用 Xcode 提供的 `productbuild` 生成 Mac App Store installer package，并用 Mac Installer
   Distribution 身份签名；
7. 使用 Apple 提供的验证/上传工具验证 `.pkg`；
8. 上传 App Store Connect，等待处理并检查警告、隐私、加密和签名状态；
9. 通过 TestFlight 安装该上传构建进行最终验收。

1.3.0 的 AppStore 构建号从 1 开始，每次上传严格递增。Direct 构建保留自己的单调构建号，
两个渠道不要求构建号相同。发布清单记录提交、渠道、版本、构建号、bundle ID、Team ID、
签名主体、SHA-256、provisioning profile UUID 和验证结果。

### 8.3 Direct 保护

AppStore 脚本不能写入、覆盖或删除：

- `dist/DropMesh.dmg`；
- Direct manifest 和 Sparkle appcast；
- Sparkle 私钥或公钥；
- 已发布 GitHub Release 和 tag；
- Direct 的签名锚、bundle ID、数据迁移或更新设置。

构建 AppStore 候选后，从同一提交单独构建 Direct 候选并执行现有签名、启动和更新契约。两套
产物写入不同的原子输出目录，失败时不能留下看似成功的旧产物。

## 9. 错误处理

- 沙盒启动失败：显示固定错误类别，设置和退出仍可用；不回退为非沙盒运行。
- 本地网络被拒绝：保留公网能力并提供系统设置入口。
- Downloads 写入被拒绝：暂停接收并要求重新授权，不改写到未告知的位置。
- 安全书签过期：提示重新选择目录，保留恢复信息。
- App Store 更新页不可用：保留当前版本信息，稍后重试，不调用 Sparkle。
- Direct 同时运行：AppStore 停止网络核心并提示退出另一版本。
- provisioning profile、证书或包签名错误：构建失败，不生成可上传标记。
- Apple 上传处理警告或错误：保留完整日志和候选哈希，修正后增加构建号重新上传。
- 审核拒绝：不影响官网版发布；根据明确条款修订后重新走全部商店门禁。

所有日志继续遵守现有敏感信息边界，不记录文件名、完整路径、文件内容、配对码、私钥、会话
密钥或原始信令载荷。

## 10. 验证矩阵

### 10.1 自动化

每次 AppStore 相关合并必须运行：

- Swift 全量测试；
- Go test、race 和 vet；
- 现有 Direct 构建、签名、分发、启动、Sparkle 和更新 Feed 契约；
- AppStore Info.plist、entitlement、provisioning、bundle ID 和数据目录契约；
- AppStore bundle 禁止 Sparkle framework、键、URL、密钥、XPC 和符号的负向检查；
- 沙盒文件访问、书签、目录权限、staging、恢复和清理测试；
- 双渠道更新适配器测试；
- 双实例保护测试；
- 简体中文和英文资源完整性、字符串泄漏和布局快照检查；
- 隐私清单格式、合并报告和第三方 framework 检查；
- installer package 内容、签名、版本和上传前验证契约。

### 10.2 真实双 Mac 验收

在最终 AppStore 签名/TestFlight 候选上验证：

- AppStore 1.3.0 ↔ AppStore 1.3.0；
- AppStore 1.3.0 ↔ Direct 1.2.6；
- AppStore 1.3.0 ↔ 同提交 Direct 1.3.0；
- Apple 芯片 ↔ Apple 芯片，以及至少一端为 Intel Mac；
- 同一局域网、不同公网直连和强制 TURN 中继；
- 单文件、多文件、文件夹、剪贴板、空文件、中文/英文/emoji 文件名和大文件；
- Finder 拖到菜单栏目标、键盘发送、通知点击、最近收到和 Finder 定位；
- 默认 Downloads、自定义目录、权限拒绝、权限恢复、同名冲突和磁盘不足；
- 暂停、继续、取消、断网、睡眠、进程重启、系统重启和断点续传；
- 移除设备后不能继续发送；
- Direct 已运行时 AppStore 不启动网络核心；
- 登录启动默认关闭，用户开启和撤销均有效；
- 中英文切换不影响传输。

每项证据记录候选提交、版本/构建、bundle ID、签名身份、系统版本、Mac 型号/架构、路线、
方向、源和目标 SHA-256、断点位置、最终路径、耗时、截图/日志位置和结果。

自动化、未签名构建、单机模拟或官网版成功不能替代 AppStore/TestFlight 沙盒候选的真实双机
验收。

## 11. 实施顺序

1. 固化当前 Direct 1.2.6 行为和包内容基线。
2. 抽出编译期渠道与更新服务接口，证明 Direct 构建无退化。
3. 新增 AppStore bundle、沙盒权限、数据域和禁止 Sparkle 的构建。
4. 适配沙盒发送、接收、书签、通知、登录启动和双实例保护。
5. 完成应用中英文和 App Store 更新界面。
6. 完成 GitHub Pages 产品、隐私和支持页面。
7. 完成生产隐私审计、隐私清单、App Privacy 和加密申报材料。
8. 创建 Apple 标识、证书、profile 和 App Store Connect 产品记录。
9. 构建、签名、验证并上传 AppStore 1.3.0 build 1。
10. 通过 TestFlight 完成真实双 Mac 验收，补齐审核资料并提交审核。
11. 处理审核反馈直至通过；整个过程中 Direct 继续独立运行。

## 12. 停止条件与成功标准

出现以下任一情况时，候选不能提交：

- AppStore 必须申请宽泛或临时例外才能完成核心功能；
- WebRTC、Bonjour、文件拖放或断点续传在沙盒内不可靠；
- AppStore bundle 仍包含 Sparkle 或可执行更新逻辑；
- AppStore 不能与 Direct 1.2.6 双向传输；
- Direct 的启动、传输、签名或更新回归失败；
- 隐私、加密、证书、provisioning、上传或真实双机证据缺失；
- 需要用户关闭 SIP、Gatekeeper、沙盒或其他系统安全功能；
- App Store 名称不可用且产品所有者尚未选择替代名称。

成功标准是：普通用户可以从 Mac App Store 免费安装 DropMesh，首次启动只根据中英文界面完成
权限授权和六位码配对，并通过菜单栏把文件、文件夹或剪贴板内容安全发送到另一台 Mac；收到
的内容经过校验后进入指定目录，通知和断点续传正常。与此同时，现有官网 1.2.6 用户的数据、
配对、传输和 Sparkle 更新完全不受影响。

## 13. 依据

- Mac App Store 应用必须启用 App Sandbox：
  <https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox>
- Apple 对 Mac App Store 的沙盒、单应用包、登录启动同意和商店更新要求：
  <https://developer.apple.com/app-store/review/guidelines/>
- 沙盒网络、Downloads 和用户选择文件权限：
  <https://developer.apple.com/documentation/security/app-sandbox>
- App Store provisioning profile 和分发证书：
  <https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile>
  <https://developer.apple.com/help/account/create-certificates/certificates-overview>
- Mac App Store 使用 installer package，Direct 分发使用 Developer ID：
  <https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution>
- 隐私政策和 App Privacy：
  <https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy>
- 隐私清单：
  <https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk>
- 加密出口合规：
  <https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance>
- 上传构建：
  <https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/>
