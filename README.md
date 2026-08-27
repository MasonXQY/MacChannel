# Mac 通道

Mac 通道是一款原生 macOS 菜单栏文件传输工具。把文件或文件夹拖到菜单栏图标，
选择一台已配对且在线的 Mac，松手即可发送。它支持多台 Mac，但每次只发送到一个目标。

> 当前尚未完成双/三台真实 Mac、生产 TURN 和 Apple 公证验收，请勿把它当作已发布版本分发。

## 使用要求

- macOS 14 或更高版本。
- 两台或更多 Mac；异地传输还需要已部署的 rendezvous 与 TURN 服务。
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

## 第一次配对

1. 在已信任的 Mac 上打开菜单栏图标，选择“添加 Mac”并显示六位码。
2. 在新 Mac 上输入六位码。
3. 两台 Mac 会显示设备名称和密钥指纹；面对面或通过可信通道逐字核对。
4. 双方确认后，新设备出现在设备列表。六位码短时有效且只能使用一次。

不要把配对码或指纹确认交给陌生人。设备遗失后，应立即在其他 Mac 的设备设置中撤销。

## 发送文件

1. 在 Finder 中选中一个或多个文件或文件夹。
2. 拖到菜单栏的 Mac 通道图标；图标显示“准备发送”。
3. 在线 Mac 设备扇展开后，把鼠标移到目标设备。
4. 看到目标高亮和“松开发送”后松手。移出所有目标再松手会取消。
5. 点击菜单栏图标可查看速度、剩余时间、连接方式、暂停、继续或取消。

连接顺序是局域网直连、互联网直连、加密中继。切换连接不会创建第二个传输任务。

## 接收位置

默认保存到 `~/Downloads/Mac 通道`。可在设置中更改全局目录，或为某个来源设备指定
单独目录。同名文件会自动编号，不会覆盖已有文件；未校验完成的内容不会以最终名称出现。

## 管理设备

在设置中可以重命名设备、关闭自动接收、限制单次大小、选择专用接收目录或撤销信任。
撤销后，该设备不能建立新的可信传输连接。

## 常见问题

- **目标没有出现：** 确认两台 Mac 已配对、应用正在运行、目标在线且允许接收。
- **显示离线：** 检查 rendezvous 地址和网络；同一局域网也要允许本地网络访问。
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
