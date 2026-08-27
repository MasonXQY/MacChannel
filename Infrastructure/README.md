# 本地 rendezvous 与 TURN 栈

从全新检出的仓库，在 macOS 安装 Docker Desktop、Go 与 OpenSSL 后，运行：

```sh
Scripts/run-local-stack.sh
```

脚本会创建仅当前用户可读的数据库密码、TURN 共享密钥和本地 CA，检测 Mac
当前局域网 IPv4，构建并启动 PostgreSQL 17、rendezvous、STUN/TURN。默认应用配置
`wss://localhost:8443/v1/ws` 无需环境变量覆盖。若自动检测不适合当前网络，或在其他
主机部署，请明确指定该主机可被客户端访问的 IPv4：

```sh
Scripts/run-local-stack.sh --turn-external-ip 192.0.2.44
```

不能使用 `127.0.0.1` 作为 TURN 对外地址：coturn 在容器 bridge 网络内运行，返回的
`XOR-RELAYED-ADDRESS` 必须是宿主机或部署入口的可达地址。脚本从宿主机实际发起
TURN Allocate，并核对服务器返回的 relay 地址。

Compose 的 secret 源文件保持目录 `0700`、私密文件 `0600`。rendezvous 与 coturn
镜像的 PID 1 先以 root 打开这些只读挂载，复制到容器私有 tmpfs、设置为运行 UID
所有的 `0400` 文件，然后清空附加组并降权 exec 服务；服务本身不以 root 运行。
PostgreSQL 官方入口同样先读取 `_FILE` secret，再降权为 postgres。启动后脚本会核验
PID 1 UID 与 tmpfs 文件所有权。

任何启动、健康检查、TLS、TURN 或日志检查失败，脚本都会停止本次 Compose 栈，并
删除本次才加入用户钥匙串的本地 CA 信任。已有信任不会被删除。只准备密钥可用
`--prepare-only --no-trust`。

所有基础镜像同时固定可读 tag 和不可变 manifest digest。可在不安装 Docker 的机器上
检查 tag 是否发生上游漂移：

```sh
Scripts/verify-image-digests.sh
```
