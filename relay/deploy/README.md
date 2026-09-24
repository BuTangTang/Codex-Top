# Ubuntu 独立部署草案

此目录只管理 Codex Top 中转。当前 Compose 静态解析通过；本机 Colima 拉取 Python 基础镜像时 registry 返回 EOF，尚未完成镜像构建、容器运行和公网验收。不能据此称阿里云已部署或 PVTC 不受影响。

## 前提与保护范围

- Ubuntu 已安装 Docker、BuildKit 与 Compose v2；使用独立目录 `/opt/codextop-relay`，不得放入 `/opt/pvtc-services`。
- 先只读确认 CPU、内存、磁盘、18766 和 HTTPS 入口端口余量，以及 PVTC 当前容器健康、8088 响应。资源不足改用独立服务器，不能从 PVTC 容器回收资源。
- 本配置使用项目 `codextop-relay`、独立卷 `codextop-relay_relay_data` 与独立网络，0.5 CPU、256 MiB 内存、64 PID、15 MiB 日志上限。不挂载 Docker socket、Codex 或 PVTC 目录，不连接其数据库。
- 容器宿主只发布 `127.0.0.1:18766`。不在安全组开放 18766；必须另有用户控制的 HTTPS 域名和证书，TLS 代理将指定域名转到本回环端口。未确认域名与端口前，不创建公网入口或改动已有代理。手机与电脑都使用该 HTTPS 地址，电脑主动发起同步，不需开放电脑入站端口。
- 同宿主的限额不能保证零影响；首次构建会下载镜像并使用 CPU/磁盘，应在资源已核验后执行，监控既有 PVTC 服务。

## 构建、初始化与启动

以下命令从本项目仓库根目录执行。服务器目录仅保存项目源文件，不包含 `.local`、认证文件或真实会话资料。构建上下文仅为 relay，BuildKit 根据 Dockerfile.dockerignore 白名单限定中转源码。缺少 BuildKit 时先修复构建环境，不能改用会忽略该白名单的旧 builder。

```sh
docker compose -f relay/deploy/compose.yaml config --quiet
DOCKER_BUILDKIT=1 docker compose -f relay/deploy/compose.yaml build relay
docker compose -f relay/deploy/compose.yaml run --rm --no-deps relay add-account your-account
docker compose -f relay/deploy/compose.yaml run --rm --no-deps relay add-device your-account mac-main "MacBook Pro"
docker compose -f relay/deploy/compose.yaml up -d --no-deps relay
docker compose -f relay/deploy/compose.yaml ps
```

预期：账号密码在终端隐藏输入；电脑令牌仅输出一次，立即写入对应电脑安全存储，不贴入消息、日志或 Git。Compose run 不发布服务端口；初始化的数据保存在同一个独立卷。第二台电脑用另一个设备 ID 重复 add-device，不能两台共用令牌。无公开注册或管理接口。

预期容器最终 healthy；健康检查只证明 HTTP 鉴权入口和 SQLite quick_check，不证明手机收到通知或 Codex 收到消息。通过 HTTPS 登录、两台电脑不同来源路由、手机移动网络收发、断线恢复、通知直达原会话仍须单独验收。

构建/启动失败只查看本项目 `docker compose ... logs --tail=50 relay`；服务只输出固定错误码。不要执行 Docker 全局重启、prune、删除其他网络/容器等操作。上线后复核 PVTC 基线与资源；出现影响只执行本项目 `stop relay`，保留数据排查，不删除卷。

## 凭据到期、丢失与撤销

手机和电脑令牌七天到期。手机重新登录；电脑由管理员轮换，并替换该电脑安全存储中的令牌。轮换会取消尚未派发的旧输入、暂时隐藏原共享列表，电脑重新同步后恢复原设备 ID；幂等身份保留。已经派发/执行的任务不能通过撤销倒退或远程取消。

```sh
docker compose -f relay/deploy/compose.yaml exec relay python -m relay.server --database /data/relay.sqlite rotate-device your-account mac-main
docker compose -f relay/deploy/compose.yaml exec relay python -m relay.server --database /data/relay.sqlite revoke-device your-account mac-main
docker compose -f relay/deploy/compose.yaml exec relay python -m relay.server --database /data/relay.sqlite revoke-mobile-sessions your-account
```

第一条只在需要轮换时执行并安全接收新令牌；第二条只在丢失/解绑时执行；第三条撤销该账号所有手机登录，不影响电脑与其他账号。不要把三条当作顺序安装步骤。自动轮换与密码找回不在当前接口范围。

## 正文、容量、备份与回退

- 正文逻辑保留 24 小时，维护每分钟运行；安全删除与 WAL 截断不保证磁盘快照或历史备份物理销毁。
- 本配置不自动备份正文，也不写请求日志；云盘快照是否包含数据卷须由管理员核验。启用备份时必须加密、限制读取权限并制定独立保留期。
- 去重记录每账号上限 10000，达到时返回 `message_quota`，不能删除记录来恢复发送，否则旧消息可能重复执行。当前需要人工容量规划，尚无无损归档方案；不能将该实现描述为无限期无人值守。
- 首次生产发布前，使用合成数据验证 SQLite 在线 backup 的一致性并实际恢复到独立临时卷；不要仅复制运行中的主 `.sqlite` 文件而遗漏 WAL。此项尚未在服务器验证。
- 回退程序只停止并替换本项目镜像，保留同一数据库卷；不要 `down -v`。如果恢复旧数据库快照，必须先阻断所有客户端，撤销恢复库中全部旧令牌，并取消所有可能已在快照之后派发的旧输入；否则旧状态可能重放。该灾备流程尚未提供自动工具，应在正式上线前完成演练。

此草案没有连接现有 Ubuntu，也没有改变 PVTC、TLS 代理、安全组或备份任务。
