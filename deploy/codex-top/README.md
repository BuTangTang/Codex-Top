# Codex Top 独立服务部署包

本目录是唯一部署配置正本，业务镜像使用相邻手机／服务端源码仓根 Dockerfile 的 **codex-top-server target**，以 SQLite 轻量模式运行一个业务服务。该专用构建入口已实现并通过源码专项及独立镜像验收；账号独立、管理员开户、不开放公众注册，D-05 不开放新建会话，D-06 保持独立手机界面。

**双服务维护已通过38项合成检查和独立 Linux 的真实 age 加密/恢复，目标双容器已健康启动且公网可信HTTPS ready通过；云端账号/WebSocket、完整恢复、证书续期和推送仍未验收。** 真实 age 检查使用实际维护函数、SQLite 和 tar，Docker/宿主边界仍为合成适配；损坏密文尾部在停服和数据变更前被拒绝。2026-09-24 主管另在独立环境完成业务镜像的 SQLite、UID1000、stdin 开户、停启持久化及 HTTP 登录/解封/Bearer 身份闭环，不把这些结果扩展为远端完整产品恢复验收。

HTTPS 接入由同一 `codex-top` 项目中的 `https` 服务提供，`manage.py` 是两个角色的唯一维护入口。主管已用官方固定 amd64 镜像在 UID1000、drop ALL、NET_BIND_SERVICE、no-new-privileges 下确认 Caddy 2.11.4；缺少该 capability 时二进制执行失败，不能通过放宽用户/privileged/关闭 no-new-privileges 绕过。本机真实 Compose 双服务解析、仓库 Caddyfile 校验、正式 CMD 启动、本地健康命令及容器内443监听均已通过；Caddy 测试无网络、无宿主端口，临时容器已清理。公网IP证书首次签发、链信任与SAN验证已通过，自动续期仍待实际验证。整体进展以 [STATUS](../../docs/STATUS.md) 为准。

## 隔离边界

| 项目 | 边界 |
| --- | --- |
| 根目录 | /opt/codex-top，root:root、700；data 为 1000:1000、700 |
| Compose | 项目 codex-top，仅 server/https，独立普通 bridge 网络 codex-top-private |
| 端口 | server 的 3005 只绑定指定宿主回环端口；https 只发布 TCP443，不占80、8088、UDP443 |
| 数据 | server 只挂 data；https 只挂只读 Caddyfile 及 https/data、https/config，不使用 PVTC 数据库、网络或卷 |
| 权限 | 两角色 UID1000、drop ALL、no-new-privileges；https 仅加 NET_BIND_SERVICE（版本、容器内443监听及健康命令已通过） |
| 资源 | 两角色各自 CPU、内存、PIDs、日志大小与数量必填；合计预检，各自禁止额外 swap |
| 备份 | age 公钥加密；容量、份数和保留余量必填，满额拒绝，不自动删除 |
| 镜像 | 预装的 SHA-256 ID 或仓库摘要；禁止自动 build/pull |

脚本只定向管理两个已核验角色，没有 down、prune、删卷或全局重启。同项目第三服务、额外挂载或实际端口漂移会被拒绝，不因项目标签相同而获得豁免。操作前后匿名邻居摘要保存在 state/neighbors-before.json 和 state/neighbors-after.json。发现其他容器状态变化会停止 Codex Top 两角色，由主管核对 PVTC；不自动归因或操作 PVTC。

日常停启不拆网络；代理通过 `server:3005` 访问业务，不能使用代理容器自己的回环地址。业务短停时，已有 WebSocket 会断开，新请求可能返回上游不可达；恢复后须实测客户端重连。若将来专门授权拆除，先核验并移除两个角色，再确认网络无其他端点；保留业务和 TLS 目录，不把拆除并入日常维护。

## 1. 独立构建

在独立构建机的 Happier 源码根目录执行。先审查源码版本和根 .dockerignore，确认 .local、所有 .env、账号、数据和诊断材料均不进入上下文。不要使用下载上游发行的 relay-server target。不要在 PVTC 服务器或当前承载 PVTC 审计容器的本机 Docker 环境构建。

codex-top-server仅安装服务端与五个共享工作区，复用原构建/迁移 owner，不构建UI/CLI。仍保留这些工作区的构建工具依赖，不能假定已做production依赖裁剪。2026-09-24主管已解决镜像仓库访问并在独立环境完成业务镜像验证及打包；具体产物版本与后续精简进展由主管记录，不在目标PVTC主机现场构建。

将 VERSION 换成已审查版本，架构按服务器实际值填写；示例为 amd64：

```sh
docker buildx build --platform linux/amd64 --target codex-top-server --tag codex-top-server:VERSION --load .
docker image inspect --format '{{.Id}}' codex-top-server:VERSION
docker save --output codex-top-server-VERSION.tar codex-top-server:VERSION
sha256sum codex-top-server-VERSION.tar
```

记录源码版本、镜像 ID、包校验值、构建日志。私密传输后由主管校验并执行 `docker load --input codex-top-server-VERSION.tar`。CODEX_TOP_IMAGE 填镜像 ID；保留镜像直到对应备份过期。不同架构重新构建。

镜像加载后必须在目标机重新 inspect，再填写当地固定 sha256 ID 或仓库摘要。containerd store 的 index ID/RepoDigest 和经典 store 的单平台 config ID 可能不同，不能把 Mac 记录直接当作远端 config ID。脚本接受这两种固定引用格式，并在目标预检记录实际 image inspect Id，启动后精确比对容器 Image；不新增导入框架，也不猜测跨 store 的 ID 等价关系。

## 2. 安装与配置

目标机需要 Linux、系统 Docker、支持 up --wait 的 Compose、Python ≥ 3.9（含 sqlite3）、age、足够资源和 PVTC 基线。脚本不安装宿主软件，仅允许本机 /var/run/docker.sock。

以下为首次安装命令；当前目录是已复制到目标机的本部署包：

```sh
sudo install -d -m 700 -o root -g root /opt/codex-top
sudo install -d -m 700 -o 1000 -g 1000 /opt/codex-top/data
sudo install -d -m 700 -o root -g root /opt/codex-top/https
sudo install -d -m 700 -o 1000 -g 1000 /opt/codex-top/https/data /opt/codex-top/https/config
sudo install -m 600 compose.yaml manage.py /opt/codex-top/
sudo install -m 644 Caddyfile /opt/codex-top/Caddyfile
sudo install -m 600 .env.example /opt/codex-top/.env
sudoedit /opt/codex-top/.env
```

若新目录继承宿主默认 ACL，`umask` 不能单独保证新文件600。首次安装应回读权限，必要时仅清除本项目新建目录继承的 ACL 并显式收紧权限；不修改 `/opt` 或其他服务的 ACL。

升级只替换本部署包代码/模板、编辑既有 .env；不得用示例覆盖正式配置，保留 data/https/state/backups。Caddyfile 是无秘密模板，644 供容器 UID1000 只读；宿主父目录仍为 root:root、700。证书、ACME 私钥和账号状态只在两个私有 TLS 目录中。维护命令从发布记录物化固定 Caddyfile，并用内容指纹标签让配置变化触发代理重建，不绑定临时目录。

两服务发布记录和归档使用 schema=2。已有数据但没有 state/release.json，或只有旧单服务记录/归档时拒绝自动接管，需要单独审核迁移；本包不会悄悄补造 TLS 状态。原有业务记录、主密钥和账号协议不变。

.env 不存密码、token 或主密钥，不支持引号、shell 插值。必填资源值由当前基线决定，不复用历史服务器余量。下列名称省略 CODEX_TOP_ 前缀：

- IMAGE/PORT：预装固定镜像和确认空闲的宿主端口。
- PUBLIC_URL：唯一的 `https://公网IPv4`，不带端口/路径/末尾斜杠。代理 IP 从这里派生；不能另外填写 PUBLIC_IP 或上游地址。正式预检拒绝非公网 IPv4；公网地址的控制权及安全组由主管另核验。
- CPUS/MEMORY/PIDS：容器 CPU 数、内存（整数加 k/m/g）、进程上限。
- LOG_SIZE/LOG_FILES：每份 Docker 日志大小及保留份数。
- HTTPS_IMAGE：预装并固定摘要的 Caddy 2.11.4 候选镜像；脚本不拉取。HTTPS_CPUS/MEMORY/PIDS/LOG_SIZE/LOG_FILES 是代理独立配额，不复用业务预算。示例配置没有生产默认值。
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

预检核对权限、两个预装镜像、公钥可用性、合计内存/CPU、磁盘、回环端口/443 与项目/网络冲突。网络只能含这两个已核验实例，不能改为 internal 网络阻断 ACME 出站。主管另记录 PVTC 的接口、CPU/内存、磁盘/IO 和业务基线；容器状态对照不能证明没有短时资源争用。

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

首次发布先启动 server 并等数据库 ready，再启动 https。业务升级先做下述完整快照，之后只让 server 保持停止，先恢复原代理继续续期；再启动新业务及检查代理。`up --no-deps` 明确限定角色，代理定义未变时无需重建。已有代理时升级必须保持同一 PUBLIC_URL；公网 IP 入口迁移需单独处理，不能将两个不同 origin 写成一致的发布记录。

停止或归档失败后，分别重新核对原容器的归属、ID、镜像和运行状态，只用 `docker start 原ID` 恢复同一已停止实例，不通过 up 重建替代实例。状态未知或身份改变时拒绝自动恢复；原来停止的角色不会被启动。一方恢复失败仍尝试恢复另一原实例。新业务启动失败保持停止，不会自动拿旧镜像读取已迁移数据；原代理可继续续期，但上游会不可达。

state/release.json 按角色记录进度，不代表健康或产品验收通过。已有代理时，业务启动前保存“新业务安装尝试 + 当前代理镜像/配额/定义”，不会提前记入尚未操作的代理版本。双镜像升级若业务启动失败，可用升级前的备份执行普通业务回滚，保留原代理与 TLS 状态。代理启动成功后才推进其记录；命令报错但已确认目标镜像的新实例替换了旧实例时，也记录该实际版本并保持停止。无法确认的漂移仍拒绝自动回滚。首次部署及显式空 TLS 灾备保存完整目标安装尝试。

两角色渲染配额必须与配置精确一致。代理本地 `/config/` 健康只说明 Caddy 进程存活；系统信任的 IP TLS、实际 WebSocket 升级/长连接和续期必须另验，不能以自签或关闭校验代替。

验收顺序：回环 /ready、管理员预建两份独立测试账号、两端登录及 A/B 归属隔离、原会话查看/收发/审批、HTTPS/WebSocket、手机通知，并对照 PVTC。开户沿用服务端 scripts/createPasswordAccount.ts 的受限 stdin 输入，由账号 owner 提供已验证命令；不把密码放入参数，不新增开户服务。原 server 在 /data/handy-master-secret.txt 生成主密钥，随数据持久化；不额外设置 HANDY_MASTER_SECRET。

正式入口需要系统信任的证书、安全组及明确的代理归属。用户确认没有域名后，候选方案改为受信任的公网IP证书，并验证短有效期证书的自动续期；不以自签证书或跳过校验替代。独立HTTPS入口须支持WebSocket/长连接，先用隔离入口验证；不得覆盖PVTC代理配置。预检通过不代表HTTPS可用，具体实施记录见REQ-002/M4。

## 4. 备份与完整回滚

```sh
# 短停两服务，完成后先恢复原代理，再恢复原先运行的业务实例。
codex_top_maint backup
# 替换为已验证备份及临时受限私钥，私钥文件权限须为 600。
codex_top_maint rollback --archive /opt/codex-top/backups/SNAPSHOT.tar.age --identity /secure/codex-top-backup.key --accept-data-loss
```

备份会短停入口与业务，向同一个 age 加密归档写入 data、https/data、https/config 及包含 Caddyfile/两镜像/配额的旧 release.json；证书私钥不能当普通文件明文备份。TLS 数据纳入相同容量预算，归档满额不会自动删除。此处短停证书自动续期是有限维护窗口；升级快照结束也恢复原代理，不使业务故障长期阻断续期。

--accept-data-loss 明确接受业务退回备份时间点，期间新增数据不自动合并。恢复先在私有暂存目录完成完整 age 认证、归档路径/链接/大小检查、SQLite/主密钥及固定镜像核对，再停 server 替换业务数据。默认保留当前 TLS 数据、代理版本及配置；当前代理镜像/配置必须匹配发布记录，旧业务 PUBLIC_URL 必须匹配当前入口。保存的记录为“旧业务 + 当前代理”，不把旧证书覆盖已续期状态。

仅完整灾备需要恢复 TLS 时，沿用同一入口显式加参数：

```sh
codex_top_maint rollback --archive /opt/codex-top/backups/SNAPSHOT.tar.age --identity /secure/codex-top-backup.key --accept-data-loss --restore-https-state
```

该模式要求安装后的两个 TLS 目录为空，且代理尚未运行或已经停止，PUBLIC_URL 与备份一致；不会清空非空目录。它恢复归档代理镜像和 TLS 状态，仍先等业务 ready 再启动代理。停止边界后还会复查空目录；发现新内容会保留文件并拒绝继续。过期证书必须由 Caddy 成功续期且经信任验证后，才能记作 HTTPS 恢复。

当前业务数据保留在 data-before-rollback-*；仍含敏感信息，按运维计划加密转存或人工清理，不自动删除。数据替换或启动阶段失败保持业务停止，不自动切换数据；明确状态后由主管处理。

先在独立 Linux 环境使用真实 age 演练账号登录、历史解密和文件读取；SQLite 完整性不是产品恢复验收。回滚后人工同步 .env 的镜像/端口/资源再进行下一次发布。备份满额需人工转存，不清理 PVTC 镜像或数据。

## 5. HTTPS 与自有推送缺口

用户没有域名，也没有现成Expo/Firebase项目。独立443与可信IP证书首次签发已通过实际公网ready检查；认证WebSocket、手机及自动续期仍需验证。推送还需：

- 自有 Expo/EAS 项目及 owner、正式 Android package/签名；构建明确设置 EXPO_PUBLIC_EAS_PROJECT_ID（或当前 app config 支持的 EAS project ID），避免上游默认项目。
- 对应 Firebase 项目、匹配包名的 google-services.json、上传到自有 EAS 的 FCM v1 服务账号凭据；秘密只用受限渠道传输。
- Expo/FCM 网络、手机 GMS/后台权限、小米锁屏送达与点击正确会话，分别验收。佳明（Garmin）已暂缓，当前验收不包含手表振动。

当前发送实现未接入 Expo enhanced push security access token，不加入无效 EXPO_ACCESS_TOKEN 并声称完成。若选择该模式，由源码 owner 增加支持；本包不修改推送协议或手机 UI。

无域名候选采用 `caddy:2.11.4-alpine` 对应的已验证固定镜像摘要及独立 TCP443，以 TLS-ALPN-01 签发 Let's Encrypt 公网 IP 证书。唯一配置正本为本目录 [Caddyfile](Caddyfile)，上游固定 `server:3005`，内容受维护脚本的已审摘要白名单约束；改变模板须共同审核校验值，不能仅修改部署机文件绕过上游边界。已接入两角色维护流程；真实 Caddy 配置、容器内监听与健康命令已由主管验证，公网签发和电脑TLS验证已通过，手机TLS尚未验收。

`PUBLIC_IP` 由唯一 PUBLIC_URL 派生，不写入用户 .env。显式 ACME issuer 避免 IP 站点默认使用本地 CA；`default_sni` 处理不发送 SNI 的 IP 客户端。只映射 TCP443 并关闭 HTTP 验证和 HTTP 自动跳转，管理接口限容器 localhost，不接管宿主80或 PVTC端口。证书只有160小时，必须实际验证自动续期及失败监测；端口无监听不能证明安全组、TLS-ALPN 透传和 ACME 出站连通。

版本与配置依据：[Caddy 2.11.4依赖](https://github.com/caddyserver/caddy/blob/v2.11.4/go.mod)、[CertMagic 0.25.3的IP与profile支持](https://github.com/caddyserver/certmagic/blob/v0.25.3/acmeissuer.go)、[TLS指令](https://caddyserver.com/docs/caddyfile/directives/tls)、[全局选项](https://caddyserver.com/docs/caddyfile/options)、[Let’s Encrypt IP证书](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)。

## 验证与参考

`python3 -B -m unittest -v test_manage` 仅使用独立临时目录、真实 SQLite/tar/文件替换。测试需要现有 PyYAML 读取实际模板，替代外部 Compose JSON 输出和 Docker 命令；age 子进程用明确的非加密管道替代。不 mock 备份/恢复等内部函数，也不调用 Docker。它不证明真实 Compose/Caddy 解析、加密、启停或公网功能；这些检查由主管在隔离环境执行。

实际验收须覆盖：固定镜像 UID/capability 和健康命令、真实 Compose/Caddy 配置、无80/8088占用和无公网裸 HTTP、受信任 IP TLS、WebSocket 长连接及维护后重连、自动续期/失败监测、真实 age 完整恢复，以及 PVTC 前后基线。无完整验收前不记为云端功能完成。

参考：[Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)、[Compose services](https://docs.docker.com/reference/compose-file/services/)、[age](https://github.com/FiloSottile/age)、[Expo FCM credentials](https://docs.expo.dev/push-notifications/fcm-credentials/)、[Expo sending notifications](https://docs.expo.dev/push-notifications/sending-notifications/)。
