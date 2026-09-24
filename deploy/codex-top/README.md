# Codex Top 独立服务部署包

本目录是唯一部署配置正本，使用相邻 Happier 源码根 Dockerfile 的 **server target**，以 SQLite 轻量模式运行一个业务服务。账号独立、管理员开户、不开放公众注册；D-05 不开放新建会话，D-06 保持独立手机界面。

**当前只有本地静态和合成检查，没有镜像构建、容器启动、远端部署、HTTPS 或推送验收。** 先在独立 Linux 环境验证真实镜像及加密恢复，再由主管操作目标服务器。健康接口不能代替业务验收。

## 隔离边界

| 项目 | 边界 |
| --- | --- |
| 根目录 | /opt/codex-top，root:root、700；data 为 1000:1000、700 |
| Compose | 项目 codex-top，唯一服务 server，独立 bridge 网络 codex-top-private |
| 端口 | 容器 3005；宿主端口按基线必填，只绑定 127.0.0.1 |
| 数据 | 只挂载本项目 data 到 /data，不使用 PVTC 数据库、Redis、网络或卷 |
| 权限 | 非 root、drop ALL capabilities、no-new-privileges |
| 资源 | CPU、内存、PIDs、日志大小与数量必填；memory+swap 上限等于内存上限 |
| 备份 | age 公钥加密；容量、份数和保留余量必填，满额拒绝，不自动删除 |
| 镜像 | 预装的 SHA-256 ID 或仓库摘要；禁止自动 build/pull |

脚本只对本项目 server 执行 up/stop，没有 down、prune、删卷或全局重启。操作前后匿名容器摘要保存在 state/neighbors-before.json 和 state/neighbors-after.json。发现其他容器状态变化会停止 Codex Top，由主管核对 PVTC；不自动归因或操作 PVTC。

## 1. 独立构建

在独立构建机的 Happier 源码根目录执行。先审查源码版本和根 .dockerignore，确认 .local、所有 .env、账号、数据和诊断材料均不进入上下文。不要使用下载上游发行的 relay-server target。不要在 PVTC 服务器或当前承载 PVTC 审计容器的本机 Docker 环境构建。

将 VERSION 换成已审查版本，架构按服务器实际值填写；示例为 amd64：

```sh
docker buildx build --platform linux/amd64 --target server --build-arg HAPPIER_BUILD_DB_PROVIDERS=sqlite --tag codex-top-server:VERSION --load .
docker image inspect --format '{{.Id}}' codex-top-server:VERSION
docker save --output codex-top-server-VERSION.tar codex-top-server:VERSION
sha256sum codex-top-server-VERSION.tar
```

记录源码版本、镜像 ID、包校验值、构建日志。私密传输后由主管校验并执行 `docker load --input codex-top-server-VERSION.tar`。CODEX_TOP_IMAGE 填镜像 ID；保留镜像直到对应备份过期。不同架构重新构建。

## 2. 安装与配置

目标机需要 Linux、系统 Docker、支持 up --wait 的 Compose、Python ≥ 3.9（含 sqlite3）、age、足够资源和 PVTC 基线。脚本不安装宿主软件，仅允许本机 /var/run/docker.sock。

以下为首次安装命令；当前目录是已复制到目标机的本部署包：

```sh
sudo install -d -m 700 -o root -g root /opt/codex-top
sudo install -d -m 700 -o 1000 -g 1000 /opt/codex-top/data
sudo install -m 600 compose.yaml manage.py /opt/codex-top/
sudo install -m 600 .env.example /opt/codex-top/.env
sudoedit /opt/codex-top/.env
```

升级只替换 compose.yaml/manage.py、编辑既有 .env；不得用示例覆盖正式配置，保留 data/state/backups。已有数据但没有 state/release.json 时拒绝自动接管，需要单独验证迁移。

.env 不存密码、token 或主密钥，不支持引号、shell 插值。必填资源值由当前基线决定，不复用历史服务器余量。下列名称省略 CODEX_TOP_ 前缀：

- IMAGE/PORT：预装固定镜像和确认空闲的宿主端口。
- PUBLIC_URL：独立 HTTPS origin，无末尾斜杠，用于正确生成文件地址；不会配置证书或代理。
- CPUS/MEMORY/PIDS：容器 CPU 数、内存（整数加 k/m/g）、进程上限。
- LOG_SIZE/LOG_FILES：每份 Docker 日志大小及保留份数。
- MIN_FREE_MEMORY_BYTES/MIN_FREE_DISK_BYTES：容器配额之外的内存保留量、操作后的磁盘保留量，十进制字节数。
- BACKUP_MAX_BYTES/BACKUP_MAX_COUNT：加密备份总容量和份数。恢复还要求最大展开预算加磁盘余量，以保留现有数据。
- BACKUP_RECIPIENT：age 公钥。离机运行 `age-keygen -o codex-top-backup.key` 创建私钥，只将公钥写入配置。业务运行不需要私钥。
- WAIT_SECONDS/STOP_SECONDS：启动健康等待和优雅停止的秒数。

```sh
# 静态解析，不访问 Docker daemon；开发机使用独立合成配置。
python3 manage.py check --env /absolute/path/to/synthetic.env
# 目标主机只读预检，不启动容器。
sudo python3 /opt/codex-top/manage.py preflight
```

预检核对权限、预装镜像、公钥可用性、内存/磁盘、端口与项目/网络冲突。主管另记录 PVTC 的接口、CPU/内存、磁盘/IO 和业务基线；容器状态对照不能证明没有短时资源争用。

维护脚本及 age 子进程需单独限额。在目标 Linux shell 中按基线导出下面四个变量：CPU 百分比（100 表示一个 CPU）、内存字节数、磁盘读/写字节每秒。变量只用于维护 scope，不写入服务 .env。先确认主机使用 cgroup v2、支持这些控制器，且 /opt/codex-top 能解析到正确块设备；复杂存储需运维指定实际设备。定义以下入口后执行后面的维护命令；缺值会停止，不设生产默认数值。

```sh
# 为本次维护及其子进程设置独立 CPU、内存、swap 和 IO 限额。
codex_top_maint() {
  sudo systemd-run --scope --unit=codex-top-maintenance \
    --property="CPUQuota=${CODEX_TOP_MAINT_CPU_PERCENT:?填写维护 CPU 百分比}%" \
    --property="MemoryMax=${CODEX_TOP_MAINT_MEMORY_BYTES:?填写维护内存字节数}" \
    --property=MemorySwapMax=0 \
    --property="IOReadBandwidthMax=/opt/codex-top ${CODEX_TOP_MAINT_READ_BPS:?填写读字节每秒}" \
    --property="IOWriteBandwidthMax=/opt/codex-top ${CODEX_TOP_MAINT_WRITE_BPS:?填写写字节每秒}" \
    python3 /opt/codex-top/manage.py "$@"
}
```

启动后由主管回读 scope 的有效限制；不支持时先在独立主机完成验证，不降级为无限额维护。[systemd-run](https://github.com/systemd/systemd/blob/main/man/systemd-run.xml) 和 [资源控制文档](https://github.com/systemd/systemd/blob/main/man/systemd.resource-control.xml)说明这些参数的作用。该 scope 不限制 Docker daemon 启动的容器，容器使用 Compose 中独立配额。

## 3. 发布

```sh
codex_top_maint deploy
```

首次发布只启动本服务；升级先停本服务、校验 SQLite、加密备份完整数据与**旧版本配置**，再启动新镜像。停止或归档失败后，会重新核对原容器的归属、ID、镜像和运行状态，仅恢复同一已停止实例；状态未知或身份改变时拒绝自动恢复，已在运行时不重复启动。新版本失败保持停止，不会自动拿旧镜像读取已迁移数据。state/release.json 记录当前安装尝试，不代表健康或产品验收通过。渲染后的 CPU、PIDs、内存和内存/交换上限必须与配置精确一致，归档配置在回滚时也适用此检查。

验收顺序：回环 /ready、管理员预建两份独立测试账号、两端登录及 A/B 归属隔离、原会话查看/收发/审批、HTTPS/WebSocket、手机通知，并对照 PVTC。开户沿用服务端 scripts/createPasswordAccount.ts 的受限 stdin 输入，由账号 owner 提供已验证命令；不把密码放入参数，不新增开户服务。原 server 在 /data/handy-master-secret.txt 生成主密钥，随数据持久化；不额外设置 HANDY_MASTER_SECRET。

正式入口仍需独立域名、DNS、证书、安全组及代理归属。建立独立 HTTPS virtual host 指向回环端口，支持 WebSocket/长连接；先用隔离入口验证。不得覆盖归属不明的 PVTC 代理配置。预检通过不代表 HTTPS 可用。

## 4. 备份与完整回滚

```sh
# 短时停服，完成后恢复原先运行的同版本。
codex_top_maint backup
# 替换为已验证备份及临时受限私钥，私钥文件权限须为 600。
codex_top_maint rollback --archive /opt/codex-top/backups/SNAPSHOT.tar.age --identity /secure/codex-top-backup.key --accept-data-loss
```

--accept-data-loss 明确接受退回备份时间点，期间新增数据不自动合并。恢复先在私有暂存目录完成解密认证、归档路径/链接/大小检查、SQLite 和主密钥校验、旧镜像核对，再停服务替换数据。当前数据保留在 data-before-rollback-*；仍含敏感信息，按运维计划加密转存或人工清理，不自动删除。启动失败保持停止，不自动切换数据。

先在独立 Linux 环境使用真实 age 演练账号登录、历史解密和文件读取；SQLite 完整性不是产品恢复验收。回滚后人工同步 .env 的镜像/端口/资源再进行下一次发布。备份满额需人工转存，不清理 PVTC 镜像或数据。

## 5. HTTPS 与自有推送缺口

HTTPS 缺域名、证书、DNS/安全组和代理归属确认。推送还需：

- 自有 Expo/EAS 项目及 owner、正式 Android package/签名；构建明确设置 EXPO_PUBLIC_EAS_PROJECT_ID（或当前 app config 支持的 EAS project ID），避免上游默认项目。
- 对应 Firebase 项目、匹配包名的 google-services.json、上传到自有 EAS 的 FCM v1 服务账号凭据；秘密只用受限渠道传输。
- Expo/FCM 网络、手机 GMS/后台权限、小米锁屏送达与点击正确会话，分别验收。佳明（Garmin）已暂缓，当前验收不包含手表振动。

当前发送实现未接入 Expo enhanced push security access token，不加入无效 EXPO_ACCESS_TOKEN 并声称完成。若选择该模式，由源码 owner 增加支持；本包不修改推送协议或手机 UI。

## 验证与参考

`python3 -m unittest -v test_manage.py` 使用真实 Compose 静态解析和合成 SQLite/归档；Docker 状态与 age 子进程边界以替代实现验证控制流，不连接 daemon，不证明真实加密、启停或公网功能。

参考：[Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)、[Compose services](https://docs.docker.com/reference/compose-file/services/)、[age](https://github.com/FiloSottile/age)、[Expo FCM credentials](https://docs.expo.dev/push-notifications/fcm-credentials/)、[Expo sending notifications](https://docs.expo.dev/push-notifications/sending-notifications/)。
