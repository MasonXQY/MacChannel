# 本地 rendezvous 与 TURN 栈

## 全新检出直接启动

Task 12 的原始入口不依赖环境变量，也不要求预先创建未跟踪 secret：

```sh
docker compose -f Infrastructure/docker-compose.yml up -d --build
curl --fail http://localhost:8080/healthz
docker compose -f Infrastructure/docker-compose.yml ps
```

一次性的 `secret-init` 容器会在名为 `macchannel-local_stack_secrets` 的
Docker volume 中安全生成数据库密码、TURN 共享密钥、本地 CA 和 localhost 证书。
每一代都有随机 generation ID 和持久 manifest，manifest 记录固定文件集合、mode、size
与 SHA-256；完成标记在所有文件及父目录同步后最后写入。标记单独丢失时会从 manifest
验证并恢复同一代，完整 pending 会原样续发；没有 manifest 却已有 live 数据则失败关闭，
绝不会猜测状态或轮换数据库密码。生成器用跨进程排他锁覆盖检查、恢复和发布，后来的
实例会等待并复用同一代。重启和普通 `docker compose down` 会保留这些材料；若要完全
重置，必须同时明确删除 `stack_secrets` 和 `postgres_data` volume。

生成过程对文件执行 `fsync`，对 rename 的源/目标父目录执行同步；macOS 优先
`F_FULLFSYNC` 并在不支持时回退 `fsync`，Linux 使用 `fsync`。live 文件完全持久化前，
pending 中仍保留同代备份，所以断电恢复不会依赖重新生成。

直接入口把 `host.docker.internal` 作为 Docker Desktop 的本地 advertised relay
默认值，足以启动 clean-checkout 栈。需要验证真实 relay 地址、系统信任和错误路径时，
应使用完整 runner：

```sh
Scripts/run-local-stack.sh
```

runner 会检测 Mac 当前局域网 IPv4，也可显式指定部署宿主机的一对一映射地址：

```sh
Scripts/run-local-stack.sh --turn-external-ip 192.0.2.44
```

它从 named volume 只导出本机验证需要的 TURN secret、公开 CA/证书和 server key，
保持目录 `0700`、私密文件 `0600`，然后校验链、hostname 与公私钥匹配。rendezvous
与 coturn 的 PID 1 则从只读 named volume 复制到容器私有 tmpfs，设置为运行 UID
所有的 `0400` 文件，再清空附加组、降权 exec；服务最终没有有效 capability。

宿主 TURN probe 会完成带 MESSAGE-INTEGRITY 的真实 Allocate，并同时核对返回的
`XOR-RELAYED-ADDRESS` 及端口处于已发布的 `49160...49200`。完整 peer 数据面验证
留给 Task 13。

## 网络与 peer 策略

- PostgreSQL 只连接 Docker internal `backend` 网络。
- rendezvous 同时连接 `backend` 与独立 `edge` 网络。
- coturn 只连接 `relay` 网络，与 PostgreSQL/rendezvous 不共享任何容器网络。
- TURN 拒绝 loopback、RFC1918、共享地址空间、link-local、IPv6 ULA/link-local peer，
  防止 relay 访问宿主或 backend。局域网设备仍可作为 TURN 客户端；局域网设备之间
  的传输使用优先级更高的直连 LAN 路径，TURN 只服务公网 fallback。

任何 runner 启动、健康检查、TLS、TURN 或日志检查失败，都会保留原始失败码，停止
本次 Compose 栈，并删除仅由本次加入用户钥匙串的 CA 信任。runner 使用固定 Compose
项目专属的宿主排他锁，所以不同 checkout 也不能并发操作同一组 named volume；
并用每进程随机 token 标记其明确创建的 stack/database volume；回滚前会重新核对
token，只有仍由本实例拥有的 volume 才会删除。已有、被其他实例接管的 volume 和
已有信任不会被删除。

所有基础镜像同时固定可读 tag 和不可变 manifest digest。无需 Docker 即可检查 tag
是否发生上游漂移：

```sh
Scripts/verify-image-digests.sh
```
