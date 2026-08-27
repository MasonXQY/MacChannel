# Mac 通道个人网络安装与异地互联设计

日期：2026-08-27  
状态：已由用户书面确认
目标平台：macOS 14 或更高版本

## 目标

让两台或多台属于同一位个人用户或受邀家庭成员的 Mac，在不购买域名、云服务器或
持续付费服务的前提下，安装同一个 Mac 通道应用后完成异地配对、菜单栏拖放传输、
断点续传和可信设备撤销。

个人网络模式依赖两端安装并登录 Tailscale Personal。Tailscale 提供跨 NAT 的加密 IP
连通性；Mac 通道继续负责设备身份、六位码配对、人工指纹确认、应用层端到端加密、
文件完整性、接收策略、历史和撤销。现有 rendezvous/WebRTC/TURN 模式保留为未来有
公共基础设施时的可选模式，不是个人网络模式的运行前置。

## 非目标

- 不在 Mac 通道安装包中捆绑、静默安装或登录 Tailscale。
- 不自动修改 Tailscale ACL、邀请用户或公开 Tailscale Funnel。
- 不要求 Docker、PostgreSQL、端口映射、公网 IP、自有域名或长期在线的第三台主机。
- 不把 tailnet 成员身份当作 Mac 通道信任；未经六位码和指纹确认的 tailnet 设备仍不可信。
- 不在本阶段实现 Windows、Linux、iOS 或 Android 客户端。
- 不以未公证构建作为公开分发完成证据；两台自有 Mac 的内部签名验收可以先行。

## 用户体验

### 安装

发布产物为 Developer ID 签名的 `MacChannel.dmg`。DMG 包含 `MacChannel.app`、指向
`/Applications` 的拖放入口，以及纯文本版本信息。旁路清单记录完整 Git commit、版本、
Team ID 和 DMG SHA-256。

首次启动按顺序检查：

1. macOS 版本至少为 14.0。
2. Tailscale CLI 是否存在于受支持的官方位置。
3. Tailscale 是否已登录并处于在线状态。
4. Mac 通道专用 Serve 端口是否空闲或已经精确指向本应用。
5. 下载目录、本地网络和通知权限是否可用。

应用只在用户点击“启用个人网络通道”后创建 Tailscale Serve 配置。未安装 Tailscale时，
界面打开官方安装说明；未登录时，界面要求用户先在 Tailscale 应用中登录。应用不得要求
关闭 Gatekeeper、系统完整性保护或系统整体网络安全。

### 配对

“添加 Mac”界面显示同一 tailnet 中可达、且响应 Mac 通道探测的设备。用户选择目标：

1. 主机生成一次性六位码，有效期十分钟。
2. 加入方选择主机并输入六位码。
3. 双方交换设备公钥和显示名称，界面显示密钥指纹。
4. 双方分别人工确认指纹；任一方拒绝或超时都不写入信任。
5. 双方确认后各自写入签名信任记录，设备进入可传输列表。

设备名称只用于显示，不参与授权。Tailscale IP、MagicDNS 名称和 tailnet 用户信息不写入
传输历史，也不上传到现有 rendezvous 服务。

### 发送和接收

现有菜单栏拖放、设备扇、准备发送、暂停、继续、取消、下载目录和同名文件编号行为不变。
个人网络传输建立一条新的应用层安全 TCP 通道，并复用现有 `TransferCoordinator`、
`SendSession`、`ReceiveSession` 和 `ReceiveStore`。

若 Tailscale 报告对端链路为 `direct`，界面显示“互联网直连”；若为 `relay` 或
`peer-relay`，界面显示“加密中继”。该标签来自连接建立后的 Tailscale 状态，不根据地址
或网络位置猜测。

## 架构

### Tailscale 集成边界

`TailscaleCommandClient` 只执行固定参数数组，不经过 shell。按顺序查找：

1. `/usr/local/bin/tailscale`
2. `/Applications/Tailscale.app/Contents/MacOS/Tailscale`

CLI 子进程使用 `TAILSCALE_BE_CLI=1`，环境变量使用最小 allowlist。所有调用最长五秒，
stdout 和 stderr 分别限制为 1 MiB；超时、非零退出、无效 UTF-8、超大 JSON 或未知 schema
均返回结构化错误。状态读取使用 `tailscale status --json`，最多接收 100 个 peer，丢弃
缺少 Tailscale IP、离线或地址不属于 Tailscale CGNAT/IPv6 前缀的条目。

`TailscaleServeConfigurator` 管理专用 tailnet TCP 端口 `51337`，映射到本机回环
`127.0.0.1:51338`。启用前读取 Serve 配置：

- 端口空闲：添加精确映射。
- 已精确映射到本应用：幂等复用。
- 指向其他目标：返回端口冲突，不覆盖。

禁用时只删除仍精确属于本应用的 `51337` 映射，不重置其他 Serve 或 Funnel 配置。
应用在本地以 owner-only 文件保存已提交映射的版本和目标，用于崩溃恢复；该文件不包含
Tailscale token、用户身份或设备列表。

### 发现

`MeshPeerDirectory` 每十五秒刷新一次 Tailscale 状态，并以最多八个并发探测连接检测
`peer:51337`。每次探测两秒超时，响应帧上限 8 KiB。探测只返回 Mac 通道协议版本、
随机会话 nonce、设备 ID 哈希和用户批准的显示名称；不返回文件、路径、历史、公钥或
信任状态。

已配对设备通过完整 DeviceID 与持久公钥绑定。未配对设备仅以当前探测 nonce 和临时
endpoint 展示；刷新后旧 endpoint 失效。重复、矛盾或超限设备条目被丢弃并显示固定类别错误。

### 监听器和协议分流

`MeshConnectionListener` 使用 Network.framework 在 `127.0.0.1:51338` 建立
`NWListener`。Tailscale Serve 是唯一 tailnet 入口；监听器不绑定 LAN 或公网接口。

每条连接先读取固定八字节 magic、协议版本、用途和长度。用途只允许：

- `probe`
- `pairing`
- `transfer`

前置帧上限 8 KiB，普通安全通道消息上限 64 KiB；长度溢出、未知用途、超时或额外字段
立即关闭。进程级限制为四条并发握手、两条活跃入站传输和三十二条排队连接，沿用现有
有界资源注册表，不创建不受控任务或 waiter。

### 六位码配对协议

个人网络配对不复用公网 rendezvous mailbox，但复用现有 `DeviceIdentity`、
`SignedTrustRecord`、`TrustRepository` 和界面状态机。

1. 主机在内存中创建十分钟有效、单次使用的六位码记录，并生成 32 字节随机 challenge。
2. 主机发送 challenge、临时 P-256 ECDH 公钥、长期身份公钥和覆盖完整 transcript 的签名。
3. 加入方验证签名结构，发送自己的临时 ECDH 公钥、长期身份公钥、签名，以及使用
   ECDH 派生密钥和六位码计算的 HMAC proof。
4. 主机只在 proof 正确、码未使用、未过期且在线尝试未超限时返回成功；错误 proof 不返回
   任何可用于离线验证六位码的主机 proof。
5. 双方界面显示从长期公钥计算的指纹。双方人工确认后，各自生成并交换方向正确的签名
   authorization record；只有两条记录都验证并持久化后配对完成。

同一主机每分钟最多五次失败、每个 endpoint 每小时最多二十次失败；触发限制只返回固定
错误类别。退出、拒绝、超时或连接中断会烧毁该码和临时密钥，不允许恢复半完成配对。

### 传输安全通道

`MeshSecureChannel` 实现现有 `SecureChannel` 接口。每次传输使用新的连接和新的双方临时
P-256 ECDH 密钥：

1. 双方交换 DeviceID、TransferID、角色、32 字节 nonce、临时公钥和长期身份签名。
2. 在派生密钥前，双方从 `TrustRepository` 重新读取当前可信公钥并验证签名。
3. HKDF 上下文绑定协议版本、双方 DeviceID、TransferID、角色、nonce、临时公钥和完整
   transcript，导出方向独立的认证密钥及现有传输 exporter。
4. 安全通道帧使用单调序号、AES-GCM 和方向独立 nonce；重放、乱序、重复、篡改或角色
   反射均关闭连接并返回现有认证失败类别。

传输载荷随后继续经过现有 Task 7 应用层加密和完整性流程。Tailscale WireGuard、
`MeshSecureChannel` 和文件传输协议形成三层独立保护；任何一层失败都不发布最终文件。

撤销设备时，`MeshConnectionRegistry` 关闭与该 DeviceID 关联的探测、配对、排队和活跃
传输连接。新连接在握手开始和密钥导出前各检查一次最新信任，避免撤销竞态。

### 路由和恢复

个人网络模式优先于公网 rendezvous 模式，但不与其同时为同一 TransferID 建立连接：

1. 若设置为“个人网络”，只使用 `MeshSecureChannel`。
2. 若设置为“公共服务”，使用现有 LAN → Internet → TURN 顺序。
3. 设置变更只影响新连接；活跃传输关闭后由同一 TransferID 通过数据库和接收 journal 恢复。

Tailscale 离线、Serve 失效或 endpoint 变化会把传输保留为可恢复状态。恢复后重新发现对端，
重新认证并使用接收端真实 `ResumeMap`；不得从零重传已确认分块。

## 持久化与隐私

- 身份私钥继续使用 `AfterFirstUnlockThisDeviceOnly` 且不可同步的钥匙串策略。
- 信任、设置、传输数据库和接收 staging 继续使用现有 owner-only 路径和原子提交合同。
- 新增设置只包含模式、专用端口、已提交 Serve 映射版本和用户批准的设备显示名称。
- 不保存 Tailscale auth key、OAuth token、tailnet 用户列表、DERP 区域历史或完整 CLI 输出。
- 生产日志只允许固定错误类别；禁止输出 Tailscale IP、MagicDNS 名、六位码、指纹、路径、
  文件名、内容或 CLI 原始 stdout/stderr。
- 子进程参数不包含 Mac 通道 secret；错误展示由结构化枚举本地化，不回显 stderr。

## 故障处理

| 故障 | 用户可见结果 | 状态处理 |
| --- | --- | --- |
| Tailscale 未安装 | 显示官方安装入口 | 不启动监听器，不改配置 |
| Tailscale 未登录或离线 | 显示“请先连接 Tailscale” | 传输保持可恢复 |
| CLI 超时或 schema 不支持 | 显示版本/重试提示 | 杀掉子进程并清理 waiter |
| Serve 端口被占用 | 显示冲突目标类别 | 不覆盖现有配置 |
| ACL 拒绝或 peer 不可达 | 目标显示离线及修复提示 | 不降级到公网裸连接 |
| 六位码错误/过期/重放 | 固定配对失败提示 | 烧毁码或计入限速 |
| 指纹拒绝 | 双方回到未配对 | 不写信任 |
| Tailscale 断线 | 暂停并显示等待网络 | 恢复后同 ID 续传 |
| 设备撤销 | 活跃通道关闭 | 新旧连接均重新校验信任 |
| 下载目录或磁盘错误 | 沿用现有明确错误 | 不发布未验证文件 |

## 构建、安装和更新

新增 `Scripts/build-distribution.sh`：

1. 要求干净 Git commit、Release 配置和 Developer ID Application 身份。
2. 调用现有 deterministic app bundler，并严格验证嵌入 framework、hardened runtime、
   timestamp、bundle ID、版本和 sealed resources。
3. 创建只含 App、Applications 链接和版本文本的确定性 DMG。
4. 若提供 notarytool keychain profile，则提交、公证、staple，并执行 `stapler validate` 和
   `spctl --assess --type open`；任何失败不发布 DMG。
5. 输出 DMG SHA-256、完整 commit、版本和 Team ID 清单。

内部两台自有 Mac 验收允许先使用同一 Developer ID 签名但未公证的 DMG，并通过 Finder
“打开”一次性确认。公开分发必须使用同一 commit 的公证/stapled DMG，且 Gatekeeper 在
一台未安装开发工具、无本地例外的新用户账户上通过。

更新覆盖 `/Applications/MacChannel.app`，不得删除 Application Support、钥匙串身份、信任、
设置、数据库、传输包或 staging。降级必须保留同样的数据兼容性；不兼容版本拒绝启动并
显示恢复上一签名构建的说明。

## 自动化验证

### Tailscale 边界

- 两种 CLI 路径、缺失、离线、超时、取消和非零退出。
- 1 MiB 边界、超大/无效 JSON、100 peer 上限、重复 endpoint 和不允许的地址。
- Serve 空闲、精确幂等、冲突拒绝、只删除自有映射及崩溃恢复。
- 子进程固定参数、最小环境、无 shell、无敏感 stdout/stderr 泄漏。

### 配对与通道

- 配对 RED/GREEN 覆盖错误码、过期、单次使用、失败限速、签名篡改、角色反射和双方确认。
- 安全通道覆盖 MITM、未知/撤销设备、密钥替换、nonce 重用、重放、乱序、超大帧、
  backpressure、取消和连接关闭生命周期。
- 两个独立本地 mesh 节点完成 2 MiB、目录、同名文件、64 MiB 断网续传和三设备定向。
- 从零重传 mutant 必须被 wire-byte/真实 `ResumeMap` 证据拒绝。

### 构建和安装

- DMG 内容、卷名、Applications 链接、版本清单和重复构建摘要。
- 错误签名、公证失败、staple 失败和不干净工作树均不得留下可分发形状的 DMG。
- 签名 App 从 DMG 拖入 Applications 后启动，重装保留身份、信任和历史。

## 真实两/三台 Mac 验收

同一签名构建至少完成：

1. Mac A 与 Mac B 分处两个外部网络，Tailscale 在线。
2. 两端 DMG 安装、首次向导和 Serve 配置成功。
3. 六位码配对、双方指纹核对、重启后信任恢复。
4. Finder 拖到菜单栏设备扇并传输文件及目录；两端 SHA-256 一致。
5. `tailscale status` 分别记录一次 `direct` 和一次 `relay`/`peer-relay`，UI 路由一致。
6. 64 MiB 与 1 GiB 传输断网后恢复，TransferID 不变、ResumeMap 非空、内存增量低于
   256 MiB。
7. 加入 Mac C 后只选定一个目标，另一台不产生文件或传输历史。
8. 撤销 B 后关闭活跃连接且无法重连，A/C 仍可互传。
9. 升级安装后身份指纹、信任、目录设置、历史和未完成传输保持。

若网络环境无法主动形成 DERP，可通过 Tailscale 官方状态确认的受控网络限制触发；不得
根据拓扑猜测路线。任何一项未运行都保留为 `NOT RUN`，不能以单机、Docker 或内存测试替代。

## 完成判定

“两台电脑可以真正安装 App 使用”必须同时满足：

- 相同 commit 的 Developer ID 签名 DMG 安装到两台真实 Mac。
- Tailscale 个人网络模式无需 Docker、服务器、域名或端口映射即可启用。
- 异地配对、菜单栏拖放、传输、下载、断网续传和撤销全部通过。
- 文件/目录哈希一致，未验证内容不以最终名称发布，第三台设备不误收。
- 自动化门禁、资源上限、静态隐私审计和真实设备记录无未解决 P1/P2。

公开下载还必须额外完成 Apple notarization、staple、Gatekeeper 和运行时隐私证据；这些
发布门禁不阻止在两台所有者控制的 Mac 上执行同一签名构建的内部真机验收。
