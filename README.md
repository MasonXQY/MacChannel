# MacChannel / Mac 通道

MacChannel 是一款原生 macOS 菜单栏文件传输工具。把文件或文件夹拖到菜单栏的纸飞机图标，选择一台已配对且在线的 Mac，松手即可发送。

## 下载

请从 [Releases](https://github.com/MasonXQY/MacChannel/releases/latest) 下载 MacChannel.dmg。

## 系统要求

- macOS 14 或更高版本
- 支持 Apple 芯片和 Intel Mac
- 两台或更多 Mac
- 推荐每台 Mac 安装 Tailscale，并登录同一个个人网络

## 安装

1. 下载并打开 MacChannel.dmg。
2. 把 MacChannel 拖到“应用程序”文件夹。
3. 从“应用程序”打开 MacChannel。
4. MacChannel 是菜单栏应用，不会显示主窗口或 Dock 图标；请在屏幕右上角寻找纸飞机图标。
5. 首次使用时，按系统提示允许通知、本地网络和接收目录访问。

## 连接两台 Mac

1. 两台 Mac 都安装并登录 Tailscale，确认位于同一个个人网络。
2. 在两台 Mac 上打开 MacChannel。
3. 点击菜单栏纸飞机图标，进入设置并选择“个人网络（推荐）”。
4. 点击“启用个人网络通道”。
5. 一台 Mac 选择“添加 Mac”并显示六位配对码；另一台选择发现的设备并输入配对码。
6. 在两台 Mac 上核对安全指纹并确认。

## 发送文件

从 Finder 把文件或文件夹拖到菜单栏纸飞机图标。出现可接收的 Mac 后，把鼠标移到目标 Mac 图标并松手。接收文件默认保存到“下载/Mac 通道”，也可以在设置中更改。

## 安全与隐私

公开安装包使用 Developer ID 签名，并经过 Apple 公证。个人网络模式通过用户自己的 Tailscale 网络发现和连接设备，不需要把文件上传到公共存储服务。

## 当前范围

本仓库用于发布安装包和校验清单，不包含源代码。当前公开版本面向个人 Tailscale 网络；公共 rendezvous/TURN 服务未随安装包提供。
