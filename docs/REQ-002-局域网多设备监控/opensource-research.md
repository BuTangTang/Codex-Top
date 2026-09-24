# 手机端类似项目调研

## 2026-09-23：优先复用的主管决定

用户明确“我们不需要重复造轮子”。已通知三个实施任务停止新增功能，保留工作并收尾验证；改为先验证开源方案。以下是本次重新查阅官方仓库与文档的结果，不是安装验收。

| 候选 | 对最新需求的匹配 | 未解决的核验点 |
|---|---|---|
| [Happier](https://github.com/happier-dev/happier) | 有直接 APK、多电脑、选择机器与目录创建会话；[Docker 中转](https://docs.happier.dev/self-hosting/docker)有现成镜像与 SQLite 方案 | 优先作为整套替代候选；已有会话查看与接管不同，[Codex 本地控制是互斥的](https://docs.happier.dev/agents/codex)，不能宣称与现有桌面 App 无缝同时操作 |
| [HAPI](https://github.com/tiann/hapi) | [原生 Android](https://hapi.run/docs/guide/native-apps)、扫码、中文、历史、选择电脑与目录新建，适合保留原生手机体验 | [共享会话](https://hapi.run/docs/guide/codex-shared-sessions)面向它启动的 TUI/app-server；原生 Android 推送需要 FCM/Google 服务，必须在小米锁屏实测 |
| [Happy](https://github.com/slopus/happy) | Android/Web、消息与审批通知、加密同步及开源后端 | README 主流程通过 happy codex 启动、切换远程模式；未证明直接接入当前桌面会话 |
| [Farfield](https://github.com/achimala/farfield) | 按项目组织会话、聊天、模型控制；适合进一步核验桌面接入方式 | 当前公开主入口是 Web；推荐 HTTPS/VPN 访问本机服务，未证实符合原生 APK、集中多电脑及锁屏通知全部要求 |

本阶段建议：先试用完整候选，再决定是否需要二次开发。完整产品优先比较 Happier/HAPI；当前桌面会话接入单独核验 Farfield。不要先把自研服务和开源客户端拼成新的维护负担。只有实际试用仍不满足的功能才进入补充开发清单。

验收关口：真实已有桌面会话读取及续发是否需要转移控制；手机选择电脑/项目并创建会话；手机网络切换；小米锁屏通知与点入正确会话；阿里云部署隔离。此次仅资料调研，没有安装第三方服务、改动 Codex 数据或接触 PVTC。

## 2026-09-22：前次记录

2026-09-22，按用户“看看 GitHub 上有没有类似的项目”只读查阅。尚未安装这些项目、复制代码、连接真实 Codex 任务或部署服务器。

| 项目 | 与本需求相关的现有能力 | 当前判断 |
|---|---|---|
| [HAPI](https://github.com/tiann/hapi) | 原生 Kotlin Compose Android、可自建 Hub、扫码配对、会话查看/回复/审批、通知 | 最值得先验证；功能方向与“手机先用、以后能操作”接近 |
| [Happy](https://github.com/slopus/happy) | Expo 手机客户端、Codex 包装运行器、扫码连接、加密同步、通知、服务端 | 适合对照账号/配对/通信设计，主流程从 `happy codex` 启动 |
| [Happier](https://github.com/happier-dev/happier) | 跨手机/桌面/Web 的多代理客户端、可自建服务、加密和远程操作 | 作为另一候选，范围更大，需独立验证维护成本与兼容性 |

## HAPI 需先验证的两点

1. **现有桌面任务的衔接**：官方 [Codex shared sessions](https://github.com/tiann/hapi/blob/main/docs/guide/codex-shared-sessions.md) 文档描述 HAPI 管理的共享 app-server、附加到其执行实例及冷恢复。它明确拒绝已有其他活动执行者的会话；这不能证明能直接接管当前 Codex 桌面正在运行的任务。Codex Top 现有关注列表、只读状态语义和既有 Codex 数据保护要求不能自动取消。
2. **小米通知**：官方 [原生客户端说明](https://github.com/tiann/hapi/blob/main/docs/guide/native-apps.md) 与 [Android 构建说明](https://github.com/tiann/hapi/blob/main/android/README.md) 表明 Android 推送依赖 Google Play services 与 FCM 连通性；没有 Firebase 配置的自编译包可使用会话功能，但没有 FCM 推送。当前手机已检测到 Google Play services 包，仅证明安装存在，不证明后台推送可达。

HAPI 使用 AGPL-3.0，Happy / Happier 的仓库标识为 MIT。若后续复制或派生代码，再针对实际组件核对许可证；本轮未引入任何第三方项目源码。

Happier 的官方 [Direct sessions 说明](https://docs.happier.dev/sessions/continuing-a-session) 明确支持浏览和跟随已有 Codex 会话，该功能为实验性，要求来源电脑可达。只跟随时不能发送或停止任务；接管是另一项显式操作，可能需要先停止原进程。因此保留当前工作方式时，应将 Happier 与 HAPI 一同优先验证。

建议先用隔离环境和合成任务验证 APK、配对、通知与 Codex 衔接，再决定复用范围。当前手机客户端视觉验收未通过，用户要求先查看类似项目图片；Happy 与 Happier 的官方 App Store 展示图是 iPhone 宣传图，不能当作安卓实测。没有自动替换工程，也不在 PVTC 生产服务器上试装。
