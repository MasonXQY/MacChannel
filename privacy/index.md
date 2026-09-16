---
layout: default
title: DropMesh Privacy
---

# DropMesh privacy notice / 隐私说明

Last updated / 更新日期: 16 September 2026 / 2026 年 9 月 16 日。

Operator: ZENSYS TECHNOLOGIES - FZCO. Privacy and support contact: [xuqy87@gmail.com](mailto:xuqy87@gmail.com).

## English

### Transfers and local data

DropMesh lets you send files to compatible devices you pair with. The Mac app also supports clipboard sending; the iPhone app lets you choose files, photos and videos. The receiving device saves content in its receiving folder. Local settings, transfer history and device trust records support this workflow. Removing a paired device does not delete files already received by that device. This release does not require a DropMesh account.

DropMesh supports direct connections and encrypted relay transfer when a direct connection is unavailable. The relay handles transfer traffic; it is not a cloud drive where you can retrieve files later. Share only with a device and person you trust.

### iPhone permissions, history and your choices

You choose content through the system Photos or Files picker. Choosing photos to send does not require a broad Photos library permission request. If you later choose Preview or Share for a sent Photos item in History, DropMesh requests Photos access to read that asset again. You can grant limited access, deny access, or change your choice in iOS Settings. Deleted assets or items outside your permitted selection may be unavailable.

For new sends, DropMesh stores a Photos asset identifier or, when supported, a Files access reference on your device. These references let you reopen originals without a permanent extra preview copy. An explicit preview/share action may retrieve an original from iCloud or your file provider and creates a temporary local copy. The app cleans temporary copies after use and attempts to recover abandoned copies at startup; interrupted or failed cleanup has no guaranteed deletion deadline. Photos thumbnails use existing permission with network requests disabled. Files thumbnails skip sources reported as dataless or not downloaded from iCloud; provider behavior can vary.

Local history can include device and transfer identifiers, device names, file names and sizes, direction, progress, status and timestamps. The app also stores read/unread markers and supported source references. Deleting or clearing iPhone history hides eligible finished, failed or cancelled records and removes their saved sent-source references. It leaves active transfers, received files and original files/photos in place. Local deletion markers and transfer-engine records remain. Clearing history is not an erasure of all local technical data, service data or existing backups. To remove a received file, delete the file itself in Files. Local app data may be included in device backups according to your system settings.

DropMesh uses local-network access to discover paired devices and establish local connections. Its iPhone WebRTC dependency includes camera APIs, but DropMesh does not offer camera capture or request camera access for file transfers. Apple and your selected storage providers handle their own permission, cloud and backup services under their terms.

### Connection and security information

Our connection service stores pseudonymous device identifiers, pairing and authorization state, revocation records, timestamps, expiry information, encrypted pairing messages, and hashed challenge and network-source identifiers. We use these records to connect paired devices, enforce trust decisions and prevent abuse. A device identifier can link activity from the same device even though you do not register a DropMesh account.

Network services and infrastructure providers process connection information such as IP addresses to deliver and protect the service. Operational logs and diagnostics may contain connection and error information. We do not describe this service as collecting no data.

### Retention and backups

Retention varies by record type. Temporary pairing records have expiry fields; authorization and revocation history can remain longer for security. Service logs currently rotate by size rather than a guaranteed number of days. We maintain database backups containing service metadata. The current backup job compresses backups and restricts access; it does not itself encrypt backup files. We do not promise a fixed deletion deadline for all copies.

### Support, providers and your choices

If you email support, we receive your email address and the content and attachments you choose to send. We use them to respond and investigate your request. Apple handles App Store purchases and TestFlight distribution under its own privacy terms. Infrastructure and email providers process information needed to provide their services.

You can stop using DropMesh, remove paired devices and delete locally received files. Contact us to request access to or deletion of service data associated with your device. We may need information to verify the request; some security or legally required records may need to remain. Do not send private keys or pairing codes with your request.

### This website

GitHub Pages hosts our support and privacy pages. Visiting them sends request information, including your IP address, to GitHub. See [GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). We have not added an advertising or analytics script to these pages. Website visits are separate from transfers between your devices.

## 简体中文

### 传输和本地数据

DropMesh 允许你向已配对的兼容设备发送文件。Mac 版还支持发送剪贴板内容；iPhone 版允许你选择文件、照片和视频。接收设备将内容保存到接收文件夹。本地设置、传输历史和设备信任记录用于支持这一流程。移除配对设备不会删除对方已经收到的文件。本版本无需注册 DropMesh 账号。

DropMesh 支持直接连接；无法直连时，可通过加密中继传输。中继处理传输流量，不提供供你日后取回文件的网盘。请只向自己信任的设备和人员分享内容。

### iPhone 权限、历史与你的选择

你通过系统“照片”或“文件”选择器选择内容。选择照片发送时，DropMesh 不需要请求广泛的图库权限。如果你之后在历史中对已发送的照片选择“预览”或“分享”，DropMesh 会请求照片访问权限，以便重新读取该资源。你可以允许有限访问、拒绝访问，或在 iOS 设置中修改权限。已删除或不在授权范围内的资源可能无法打开。

对于新发送的内容，DropMesh 会在设备上保存照片资源标识，或在系统支持时保存“文件”访问引用，用于重新打开原件，无需永久保留一份额外的预览副本。你主动预览或分享时，应用可能从 iCloud 或文件提供商取回原件，并创建临时本地副本。应用会在使用结束后清理临时副本，并在启动时尝试清理遗留副本；中断或清理失败时，没有保证的删除期限。照片缩略图使用已有权限，并关闭网络请求；文件缩略图会跳过系统标记为未落地或尚未从 iCloud 下载的内容，不同提供商的行为可能不同。

本地历史可能包含设备和传输标识、设备名称、文件名称和大小、传输方向、进度、状态及时间。应用还会保存已读/未读标记和受支持的原件引用。删除或清空 iPhone 历史会隐藏符合条件的已完成、失败或取消记录，并移除这些记录保存的已发送原件引用。正在进行的传输、已接收文件以及原始文件或照片保持不变。本地删除标记和传输引擎记录仍然保留。清空历史不等于抹除全部本地技术数据、服务端数据或已有备份。如需移除已接收文件，请在“文件”中删除文件本身。系统可能按你的设置将本地应用数据纳入设备备份。

DropMesh 使用本地网络权限发现已配对设备并建立局域网连接。iPhone 安装包的 WebRTC 依赖包含摄像头接口，但 DropMesh 不提供拍摄功能，也不会为文件传输请求摄像头权限。Apple 和你选择的存储提供商按各自条款处理权限、云服务与备份。

### 连接和安全信息

连接服务保存设备标识符、配对和授权状态、撤销记录、时间戳、过期信息、加密配对消息，以及经过哈希处理的验证和网络来源标识。我们使用这些记录连接已配对设备、执行信任决定并防止滥用。虽然无需注册 DropMesh 账号，同一设备的标识符仍可关联该设备的活动。

网络服务和基础设施提供商处理 IP 地址等连接信息，以提供服务和维护安全。运行日志和诊断信息可能包含连接及错误信息。本服务并非“不收集数据”。

### 保留与备份

不同记录的保留方式不同。临时配对记录设有过期字段；授权和撤销历史可能因安全用途保留更久。目前服务日志按容量轮换，并非保证在固定天数内删除。我们备份包含服务元数据的数据库。现有备份任务压缩文件并限制访问，但任务本身不加密备份文件。我们不承诺所有副本均在同一固定期限内删除。

### 支持、服务商与你的选择

你通过邮件联系支持时，我们会收到你的邮箱地址，以及你选择发送的内容和附件，用于回复和调查问题。Apple 根据其隐私条款处理 App Store 购买和 TestFlight 分发；基础设施和邮件服务商处理提供相应服务所需的信息。

你可以停止使用 DropMesh、移除配对设备并删除本地接收的文件。如需访问或删除与设备相关的服务数据，请联系我们。我们可能需要信息来核验请求；部分安全或法律要求的记录可能需要保留。请勿在请求中发送私钥或配对码。

### 本网站

GitHub Pages 托管我们的支持和隐私页面。访问页面时，GitHub 会收到包括 IP 地址在内的请求信息，详情见 [GitHub 隐私声明](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)。我们没有在这些页面中添加广告或分析脚本。访问网站与设备之间的文件传输是不同的处理流程。
