# 个人网络模式隐私边界

个人网络模式使用 Tailscale 提供的私有寻址与 NAT 穿透，但 MacChannel 仍在两端设备之间建立
自己的签名握手和端到端加密通道。Tailscale 节点地址、MagicDNS 名称和连接方式只用于本机
发现、连接与界面状态，不写入 MacChannel 传输历史，也不得进入应用、脚本或服务日志。

## 静态门禁

`Scripts/audit-privacy.sh --static-only` 会运行敏感日志 mutant。Swift、Go 与 shell 中将以下
类别传给日志输出都必须失败：

- Tailscale IP、MagicDNS/主机名和连接诊断 stdout/stderr；
- 六位配对码、设备安全指纹与私钥；
- 文件名、完整路径和文件内容。

固定错误类别可以记录，但不能拼接上述值。测试用例只使用人工 token 验证扫描器，不把真实
设备或网络标识写入测试输出。

## 数据流与保留

- Tailscale CLI 输出只在客户端内存中解析，设有大小、超时和 UTF-8 边界。
- rendezvous、TURN 和 PostgreSQL 不参与个人网络模式传输。
- 传输文件只存在于发送端私有 outgoing 包、接收端私有 staging 和用户选择的最终目录。
- 本机信任快照、恢复数据库和设置使用设备所有者权限；撤销会关闭该设备当前持有的 mesh 连接。
- 自动化证据只记录固定类别、路由枚举和哈希，不记录 IP、主机名、文件名或原始 CLI 输出。

## 未完成的运行时证据

本机双实例测试证明协议和存储路径可运行，但不等于两台真实 Mac 的日志审计。真实设备上的
Tailscale 客户端日志、MacChannel 进程日志和系统诊断仍为 **NOT RUN / BLOCKED**。
仓库现有运行时隐私门禁继续固定返回状态 2；在独立可信 producer、固定信任根和验签器完成前，
不得从自制 JSON 或自签证据得到 `RUNTIME PASS`。
