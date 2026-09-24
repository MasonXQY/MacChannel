# iOS 首发隐私与支持文字证据

日期：2026-09-16。状态：本地文案已更新，未发布网页、未修改 ASC 声明、未访问生产日志或用户数据。不是法律合规结论或发布批准。

## 交付与适用范围

更新 `AppStore/metadata/privacy.md`、`AppStore/metadata/support.md` 的中英文，保留 Mac 功能并加入 iPhone。未把下一阶段账号系统写成现有功能。未承诺不收集数据、备份加密、固定删除期限、任意文件提供商均不会下载，或清空历史等于彻底抹除数据。

| 文案主题 | 本次源码/材料证据 | 表述边界 |
| --- | --- | --- |
| 设备与权限 | `iPhone/project.yml` iOS 17；`iPhone/App/Info.plist` Photos、本地网络、依赖摄像头用途文字 | 权限用途字符串不是权限已获准或已实机验收的证据 |
| 照片选择与再次预览 | `MobileSendView.swift` 的 `.shared()` PhotosPicker；`MobilePhotoImport.swift` 按顺序记录资源标识；`MobilePhotoHistorySource.swift` 在显式 resolve 时请求 readWrite，接受 limited | 选择发送不请求广泛图库权限；历史预览/分享才按需请求；用户可拒绝或限制 |
| 被动缩略图 | Photos 查询已有权限，网络关闭；Files 无 UI/挂载解析，拒绝未下载 iCloud 和 `SF_DATALESS` | 不声称所有第三方提供商行为都已验证 |
| Files 与临时副本 | `MobileFilesPicker.swift` open-in-place；`MobileImportService.swift` 在导入时保存原件 bookmark；`MobileSentSourceStore.swift` 临时 staging、release/recover | 原件引用不是永久预览缓存；失败/中断清理不承诺固定时间 |
| 本地历史 | `MobileHistoryModel.swift` 已读ID；`MobileHistoryItemsIndex.swift` 文件元数据；`MobileSentSourceStore.swift` 访问引用/Photos IDs | 文件名、设备标识、状态等本地数据要披露；本地处理不自动等于开发者收集 |
| 历史删除 | `MobileHistoryDeletionStore.swift` tombstone；`MobileTransferHistory.delete` 仅终态；生产 session 清理已删除记录引用 | 隐藏历史，保留引擎行与删除标记；不删接收文件、原件、活动传输或服务数据 |
| 接收位置 | `MobileStorageLayout.swift` Documents/DropMesh；Info.plist Files sharing；`MobileReceivedFolderNavigation.swift`/Button 的外部打开与picker fallback | 文件夹定位为best effort，不保证Files精确跳转 |
| 系统备份 | 只发现 `ShareBatchStore.swift` 对共享批次目录设置 excludedFromBackup；未发现全部本地状态排除 | 不承诺全部应用数据不进入系统备份或删除历史会删除旧备份 |
| 服务元数据/备份 | `production-privacy-config-review.md`，2026-09-10只读生产配置、schema观察 | 不是本次live复核：日志容量轮换；pg_dump+gzip本身不加密；不作固定期限保证 |

旧 `privacy-audit.md` 中14天日志合同、七天清理描述是历史要求/静态设计，不能当作已经观察到的生产保证。按9月10日配置证据保留公开说明，提交前仍需确认生产实践未变。

## ASC 声明建议与待确认项

下表是证据建议，不是已提交答案。2026-09-16核对 [Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)：声明关注开发者/合作方可访问的离设备数据；App Functionality也须考虑；第三方SDK应纳入。支持请求的可选披露条件不能仅凭“用户主动发邮件”推定全部满足。

| 类别 | 建议与依据 | 未决项 |
| --- | --- | --- |
| Device ID | 保留“收集 / App Functionality / 与身份关联 / 非跟踪”的审阅候选；生产schema确有持久设备UUID | 最终iOS包、服务路径和保留实际行为对应 |
| Other Diagnostic Data | 既有草稿可作为起点：连接/错误运行信息用于服务维护 | live字段、Apple/TestFlight与第三方诊断接收范围、关联关系 |
| Other Data Types | 既有草稿对应来源哈希、授权/撤销状态 | 原始IP、基础设施/边缘日志、监控、供应商副本的正确分类与实际保留 |
| Photos or Videos / Other User Content | 本地选择、文件引用和用户指定对端传输不能单凭权限推定为开发者收集，也不能直接填“无收集” | direct/relay链路、服务器日志/存储和SDK是否让运营方访问/留存内容的最终证据 |
| Email Address / Customer Support | 联系邮件和附件确实可能交给支持方 | support邮箱处理商、访问/保留，以及可选披露条件是否满足；不要默认为豁免 |
| Tracking | 源码未引入广告用途，旧草稿为非跟踪 | 最终依赖和隐私报告、运营用途确认；该判断不代表无元数据收集 |

HANDOFF 记录9月10日曾把Device ID、Other Diagnostic Data、Other Data Types存为ASC草稿；本次没有查看/修改实时ASC状态，不把历史草稿当成发布完成。

## 最终包隐私清单缺项

本次枚举预恢复候选1.0(7)实际IPA，仅见 `Frameworks/WebRTC.framework/PrivacyInfo.xcprivacy`，未见主App或Share自有清单。主App使用UserDefaults并访问文件元数据；Share也使用文件元数据。需按最终源码调用核对required-reason APIs，补最小准确声明并核验最终归档。框架的清单不能自动替代App自身调用；不应把SDK理由代码照抄。后续清单修复独立记录，build7不是提交候选。

### 9月16日自有清单修复（源码已冻结，等待最终包核验）

新增 `iPhone/App/PrivacyInfo.xcprivacy`、`iPhone/ShareExtension/PrivacyInfo.xcprivacy`。`iPhone/project.yml` 对发布目标显式配置资源，并排除目录重复收录；TestHost只收录App版本。现有Mac与WebRTC清单均未修改。此次仅声明required-reason API，不添加尚未定论的收集类别或tracking字段。

官方来源：2026-09-16读取 [Apple required-reason说明](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) 和 [NSPrivacyAccessedAPIType完整类别/理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。后者Markdown视图未展开possibleValues，本次通过其[官方DocC JSON](https://developer.apple.com/tutorials/data/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype.json)核对全部类别与理由，不依赖第三方代码表。

| 目标 / 类别 | 理由 | 当前调用证据与用途 |
| --- | --- | --- |
| App + Share / FileTimestamp | C617.1 | `ShareBatchStore.swift:115–116,169–170`读取App Group临时批次元数据/时间以清理；`MobileImportCopy.swift:118`等安全检查；App的历史索引/接收目录/数据库均为本地容器文件 |
| App + Share / FileTimestamp | 3B52.1 | `MobileImportCopy.swift:41`检查用户授予文件的类型/大小；App `MobileSentSourceStore.swift:71`检查用户选中Files源；只对授予的文件进行操作 |
| App / DiskSpace | E174.1 | `ReceiveStore.swift:31–41,1862–1865`检查空间，空间不足时不接收写入；不声明磁盘分析或诊断上传用途 |
| App / UserDefaults | CA92.1 | `MobileHistoryModel.swift:113–125`使用standard保存本应用已读传输ID；不是共享UserDefaults suite，因此不使用1C8F.1 |

Apple将stat/fstat/lstat/fstatat也列入文件时间类别，故只取大小/权限仍有声明。扫描App、Shared、ShareExtension、MobileRuntime及静态链接MacChannelCore：自有代码未调用清单所列systemUptime/mach_absolute_time或activeInputModes，因此不照抄WebRTC的SystemBootTime理由。Share不链接MacChannelCore，也不声明App专用空间/UserDefaults类别。WebRTC保留自己的框架级声明；不把SDK空收集数组当成整个产品“无数据收集”结论。

验证：先新增 `Scripts/test-ios-privacy-manifests.rb`，运行得到预期RED（缺失App manifest）；添加清单与配置后GREEN，`git diff --check`通过。测试验证准确理由集合、显式资源配置、重复排除和不夹带未审阅收集声明。静态测试不等于已打包；主任务生成项目并构建最终候选后，应运行 `ruby Scripts/test-ios-privacy-manifests.rb <归档或导出的DropMesh.app绝对路径>`，核验App根及PlugIns/DropMeshShare.appex两份实际清单。App Store验证/聚合隐私报告仍是独立发布检查。

## 实际 GitHub Pages 来源与发布方式

2026-09-16通过只读GitHub API确认：

- 仓库：`MasonXQY/MacChannel`；Pages `build_type=legacy`，来源 `gh-pages` 分支根目录 `/`，状态 `built`。
- 当前分支提交：`6fdc6506cc956e0b7571338635fabe0fedaa921a`，2026-09-10 13:21:27 UTC。
- 页面源码：`privacy/index.md`、`support/index.md`；两者有 `layout: default`/title YAML头，正文仍是旧Mac说明。
- `_config.yml` 使用 `jekyll-theme-primer`；发布路径为分支推送后由GitHub Pages构建，而非本iPhone分支自动同步。
- 公开地址：[隐私](https://masonxqy.github.io/MacChannel/privacy/)、[支持](https://masonxqy.github.io/MacChannel/support/)。API已确认站点配置与源码，本次没有推送或以本地改动声称上线。

批准发布后，将这两份metadata正文同步到独立gh-pages checkout对应index.md，保留YAML头；只提交页面变更并推送该分支，随后核验Pages构建与中英文HTTPS正文。不要将内部证据报告、私有日志或产品源码复制到站点。当前无gh-pages本地worktree，需届时建立独立checkout，不能切换正在开发的iPhone工作树。

## 验证与剩余发布工作

检查两语义对齐、文内链接、无重复标题、diff空白错误；运行现有metadata文本检查（该检查仅覆盖商店12个字段，不替代本文政策审阅）。最终候选仍需确认重装恢复说明、实际权限/云端预览行为、归档privacy清单/聚合报告、服务/支持处理信息及ASC一致性。页面尚未发布。
