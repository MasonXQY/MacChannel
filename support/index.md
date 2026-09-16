---
layout: default
title: DropMesh Support
---

# DropMesh Support / 使用帮助

Contact / 联系我们: [xuqy87@gmail.com](mailto:xuqy87@gmail.com)

Updated / 更新日期: 16 September 2026 / 2026 年 9 月 16 日。

DropMesh supports macOS 14 and later and iPhone with iOS 17 and later. Operator / 运营方: ZENSYS TECHNOLOGIES - FZCO.

## English

### Start and pair

Open DropMesh from Applications and look for its icon in the menu bar at the top of your screen. It is a menu-bar app; you do not need a Finder window to keep it running. Open DropMesh on both Macs. Generate a pairing code on one Mac, enter it on the other, and approve the request on the first Mac. Pair only with a device you recognize.

On iPhone, open DropMesh and choose Devices, then Pair a Device. Open the app on both compatible devices, generate a code on one, enter it on the other, and approve the request on the first device. This release does not require a DropMesh account.

### Send, receive and manage history on iPhone

In Send, choose Photos & Videos or Files, select content and one or more available paired devices, then tap Send. Selecting content alone does not send it. Switching tabs keeps your selection. During a transfer, keep DropMesh in the foreground on iPhone and keep the other device awake with DropMesh running.

History has All, Received and Sent filters. Open a single file to preview it, or open a batch to choose individual files. Old records may lack file details or a usable source. Received files are under On My iPhone → DropMesh → DropMesh in Files. The Received files folder button tries to open that location; iOS may show a system file browser where you can navigate to it.

The Photos picker lets you select items to send without a broad library-permission request. Reopening a sent Photos item from History requests Photos access on that action. Allow access to the intended asset or adjust DropMesh permission in iOS Settings. Browsing History does not trigger a new permission request. Explicit preview/share actions may download originals from iCloud or your file provider. Limited permission, deleted originals, offline cloud content or revoked Files access can prevent preview. Files references are available only for supported new sends; the app cannot reconstruct old references. A type icon means a thumbnail is unavailable, so try opening the item to check its current availability.

Swipe a terminal history record to delete it, or use Edit to select records. Clear History applies across filters after confirmation and preserves active transfers. History deletion leaves received files and originals in place. To remove a received file, delete it in Files. Local deletion markers and transfer-engine records remain; history deletion does not erase service data or existing backups. See the [privacy notice](https://masonxqy.github.io/MacChannel/privacy/).

### Send and receive on Mac

Drag a file onto the menu-bar icon and choose a paired Mac, or use the send-files command. Keep both Macs awake and DropMesh running during transfer. Use the clipboard-send command to send supported clipboard content. Received content goes to the receiving folder under Downloads, or the folder you selected and authorized in settings. Open recent arrivals or transfer history to reveal a received file in Finder.

### A device is offline or a transfer fails

Check that both Macs are awake, connected to a network, and running DropMesh. Check the service connection status on both devices. For local transfers, allow local-network access if macOS asks. For receiving, choose a writable folder in settings and grant access if prompted. Internet transfers also depend on the relay service and both networks. Include the exact error message when contacting support.

For iPhone, keep the app in the foreground and allow local-network access in iOS Settings for local discovery. Use the retry or cancellation controls shown by the app. If startup fails after reinstalling, contact support with the displayed error and version/build. If and only if the app shows Recreate Identity, read its confirmation and choose it to create a new device identity. Existing pairings will stop working and must be created again; received files remain. This option is limited to the specific reinstall state detected by the app and is not a recovery action for other errors. Save received files you need before uninstalling; removing an app can remove local files. Avoid repeated uninstalling or identity resets as general troubleshooting steps.

### Store and standalone editions

The Mac App Store edition updates through the App Store. TestFlight builds update through TestFlight. The standalone edition has a separate local identity. Pair your Macs again after switching editions, and avoid running both editions together.

### Report a problem

Email the device models, iOS/macOS versions, DropMesh version/build, the step that failed, and whether the devices share a local network. You may attach a screenshot after hiding private file names and other personal information. Do not send pairing codes, private keys or passwords. Send a transferred file only if support explains why it is needed and you choose to share it.

## 简体中文

### 启动与配对

从“应用程序”打开 DropMesh，在屏幕顶部菜单栏找到图标。它是菜单栏应用，无需保持 Finder 窗口打开。两台 Mac 都启动 DropMesh，在其中一台生成配对码，在另一台输入，然后回到第一台批准请求。只与自己认识的设备配对。

在 iPhone 上打开 DropMesh，进入“设备”，选择“配对设备”。两台兼容设备均打开应用，在一台生成配对码，在另一台输入，然后回到第一台批准请求。本版本无需注册 DropMesh 账号。

### 在 iPhone 上发送、接收与管理历史

在“发送”中选择“照片与视频”或“文件”，选好内容后，勾选一台或多台可用的已配对设备，再点“发送”。选择内容本身不会发送，切换标签会保留选择。传输期间，请让 iPhone 上的 DropMesh 保持前台，并让另一台设备保持唤醒、运行 DropMesh。

“历史”支持“全部”“接收”“发送”筛选。打开单个文件可预览；打开批次后可选择其中的文件。旧记录可能缺少文件明细或有效原件引用。接收文件位于“文件”中的“我的 iPhone → DropMesh → DropMesh”。“接收文件夹”按钮会尝试打开该位置；iOS 也可能显示系统文件浏览器，需要你手动找到文件夹。

系统照片选择器允许你挑选发送内容，无需广泛的图库授权。在历史中重新打开已发送照片时，DropMesh 才会请求照片访问权限。请允许访问对应资源，或在 iOS 设置中调整 DropMesh 权限。浏览历史不会触发新的授权请求；主动预览或分享时，应用可能从 iCloud 或文件提供商下载原件。有限权限、原件已删除、云端资源离线或文件授权失效，都可能导致无法预览。文件引用只适用于受支持的新发送内容，应用无法补回旧引用。显示文件类型图标表示缩略图不可用，可以尝试打开条目检查当前可用情况。

滑动已结束的历史记录可删除，也可使用“编辑”选择多条记录。“清空历史”经确认后对所有筛选范围生效，正在进行的传输保留。删除历史不会删除接收文件或原件；如需删除接收文件，请在“文件”中操作。本地删除标记和传输引擎记录仍然保留；历史删除不清除服务端数据或已有备份。详情见[隐私说明](https://masonxqy.github.io/MacChannel/privacy/)。

### 在 Mac 上发送与接收

把文件拖到菜单栏图标，选择已配对的 Mac；也可通过菜单选择文件发送。传输期间，两台 Mac 都应保持唤醒并运行 DropMesh。剪贴板发送功能支持发送适用的剪贴板内容。接收内容保存到“下载”下的接收文件夹，或你在设置中选择并授权的文件夹。可从最近收到的文件或传输历史中，在 Finder 中显示文件。

### 设备离线或传输失败

确认两台 Mac 均已唤醒、联网并运行 DropMesh，检查两边的服务连接状态。局域网传输时，如 macOS 提示，请允许本地网络访问。接收失败时，在设置中重新选择可写入的接收文件夹，并按提示授权。互联网传输也依赖中继服务和两边的网络。联系支持时请提供准确的错误提示。

在 iPhone 上，请让应用保持前台，并在 iOS 设置中允许本地网络访问以使用局域网发现。使用应用显示的重试或取消操作。如果重装后无法启动，请将提示和版本/构建号发给支持。仅当应用显示“重新创建身份”时，阅读确认说明后选择该操作来创建新的设备身份；旧配对会失效，必须重新配对，已接收文件会保留。此选项仅适用于应用检测到的特定重装状态，并不能恢复其他错误。卸载前先另存需要的接收文件；移除应用可能删除本地文件。不要将反复卸载或重置身份作为通用排障步骤。

### 不同安装渠道

Mac App Store 版本通过商店更新，TestFlight 版本通过 TestFlight 更新。独立下载版使用单独的本地身份；切换版本后需要重新配对，请避免同时运行两个版本。

### 反馈问题

请邮件提供设备型号、iOS/macOS 版本、DropMesh 版本及构建号、失败步骤，以及两台设备是否处于同一局域网。截图前请遮挡私人文件名和个人信息。不要发送配对码、私钥或密码；只有在支持人员说明用途且你愿意分享时，才提供传输文件。
