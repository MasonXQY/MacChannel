# DropMesh

DropMesh 是一款原生 macOS 菜单栏文件传输工具。把文件或文件夹拖到菜单栏图标，
选择一台已配对且在线的 Mac，松手即可发送。它支持多台 Mac，但每次只发送到一个目标。

> v1.2.0 是首个内置应用更新功能的版本。从 v1.1.10 升级需要最后一次手动下载
> 官方公证 DMG 并覆盖安装；从 v1.2.0 开始，后续版本可以在应用内检查和安装。
> 自动化的签名、公证和更新验证不能替代真实双 Mac 传输验收；未执行项以验收表为准。

## 使用要求

- macOS 14 或更高版本。
- 两台或更多 Mac。
- 无需安装辅助网络软件、注册账户或填写服务器地址。
- 异地传输由应用内置的安全服务自动建立连接。
- 首次打开时允许应用访问本地网络、通知和所选下载目录。

## 本地构建与打开

```sh
bash Scripts/build-app.sh
open .build/MacChannel.app
```

这是开发构建。正式签名构建必须指定 Developer ID 和非文件同步目录作为输出位置：

```sh
MACCHANNEL_BUILD_CONFIGURATION=release \
MACCHANNEL_CODESIGN_IDENTITY="Developer ID Application: 组织名称 (TEAMID)" \
MACCHANNEL_APP_OUTPUT="/tmp/MacChannel.app" \
bash Scripts/build-app.sh
```

构建器会启用 hardened runtime、签名嵌入 framework，并申请可信时间戳。正式分发前仍须完成
Apple 公证、staple 和 Gatekeeper 验证；不要关闭系统整体安全设置。

## 制作可安装镜像

工作树必须没有未提交改动，并使用已安装的 Developer ID Application 身份：

```sh
MACCHANNEL_CODESIGN_IDENTITY="Developer ID Application: 组织名称 (TEAMID)" \
bash Scripts/build-distribution.sh
```

完成后得到 `dist/DropMesh.dmg` 和对应的 `dist/DropMesh.manifest.json`。打开 DMG，
把 DropMesh 拖到“应用程序”即可。若设置 `MACCHANNEL_NOTARY_PROFILE`，构建器还会等待
Apple 公证、装订票据并执行 Gatekeeper 检查；未设置时清单会明确标为
`internalSignedNotNotarized`。

## 在两台 Mac 上安装

1. 在每台 Mac 打开同一个 `DropMesh.dmg`，把 DropMesh 拖入“应用程序”。
2. 启动后在菜单栏找到 DropMesh 图标；应用没有主窗口。
3. 在已有设备上选择“添加另一台 Mac”并显示六位码。
4. 在新设备输入该号码，然后在已有设备点“允许”。
5. 从 Finder 把文件或文件夹拖到 DropMesh 菜单栏图标，再放到目标 Mac 图标上。

设置、信任、历史和未完成传输会在覆盖升级时保留。公开版本应当通过 Apple 公证；不要关闭
Gatekeeper 或 SIP，也不需要修改系统网络设置。

## 软件更新

设置会显示当前版本和构建号。DropMesh 每天最多在后台检查一次更新；没有更新或临时
离线时不会弹窗打扰。发现新版后，用户可以从设置或菜单栏主动查看发布说明并决定是否
安装，不会静默强制更新。

若安装时仍有文件传输，更新可以先完成下载和验证，但重新启动会等待全部活动传输结束。
从 v1.1.10 升级到 v1.2.0 时，请从
[官方 GitHub Releases](https://github.com/MasonXQY/MacChannel/releases) 下载本次
公证 DMG，拖入“应用程序”并选择“替换”；这是迁移到应用内更新通道所需的最后一次
手动 DMG 安装。

## 第一次配对

1. 在已有的 Mac 上选择“添加另一台 Mac”→“在这台 Mac 上显示配对码”。
2. 在新 Mac 上选择“输入配对码”，输入六位数字。
3. 已有 Mac 显示新设备名称后点“允许”。
4. 两端显示“已连接”后，新设备会出现在设备列表。

配对码五分钟内有效且只能使用一次。不要把配对码交给陌生人；设备遗失后，应立即在其他
Mac 的设置中移除它。

## 发送文件

1. 在 Finder 中选中一个或多个文件或文件夹。
2. 拖到菜单栏的 DropMesh 图标；图标显示“准备发送”。
3. 在线 Mac 设备扇展开后，把鼠标移到目标设备。
4. 看到目标高亮和“松开发送”后松手。移出所有目标再松手会取消。
5. 点击菜单栏图标可查看速度、剩余时间、连接方式、暂停、继续或取消。

连接顺序是局域网直连、互联网直连、加密中继。切换连接不会创建第二个传输任务。

## 接收位置

默认保存到下载文件夹中的现有接收目录（覆盖升级时保持不变）。可在设置中更改全局目录，或为某个来源设备指定
单独目录。同名文件会自动编号，不会覆盖已有文件；未校验完成的内容不会以最终名称出现。

## 管理设备

在设置中可以重命名设备、关闭自动接收、限制单次大小、选择专用接收目录或撤销信任。
撤销后，该设备不能建立新的可信传输连接。

## 常见问题

- **目标没有出现：** 确认两台 Mac 已配对、应用正在运行、目标在线且允许接收。
- **显示离线：** 检查网络；同一局域网也要允许本地网络访问。应用会自动重连。
- **下载失败：** 检查磁盘空间和接收目录写入权限，或在设置中重新选择目录。
- **传输中断：** 保持两端应用运行；恢复网络后会复用已确认的分块继续。
- **异地直连失败：** 应自动降级到加密中继；若没有，联系服务管理员检查 TURN 健康和端口。

## 开发与验证

```sh
swift test --no-parallel
cd Services/rendezvous && go test -race ./... && go vet ./...
bash Scripts/verify-e2e.sh --local-only
```

完整服务与 relay 验证需要 Docker：

```sh
bash Scripts/verify-e2e.sh
```

发布前还必须填写 [真实 Mac 验收表](docs/acceptance/real-mac-checklist.md)，完成
[隐私审计](docs/security/privacy-audit.md)，并遵循
[生产部署与回滚手册](docs/operations/deployment.md)。自动化测试或单机演示不能替代这些门禁。
