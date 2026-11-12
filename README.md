# Codex Top

**简体中文** · [English](README.en.md)

在桌面上盯住 Codex 和 Claude Code 的任务：哪些在跑、哪些在等你、哪些刚做完，不用来回切窗口。

原生 macOS 应用（SwiftUI + AppKit），当前源码与本机安装为 **v1.0.0 build 161**。[已发布安装包](https://github.com/BuTangTang/Codex-Top/releases)单独记录版本。跨平台的 Qt 版正在开发中，见[后面](#跨平台qt-版开发中)。

## 安装

- 要求 **macOS 14+**，提供 Apple 芯片／Intel 通用 DMG。
- 从[已发布版本](https://github.com/BuTangTang/Codex-Top/releases)下载 DMG，把 `Codex Top.app` 拖进“应用程序”，打开即可。
- 读 Codex 任务需要本机装有 Codex 并有任务记录；读 Claude Code 会话需要本机装有 Claude Code；Codex 额度需要官方 Codex CLI 已登录。不用在本工具里填任何 API Key。
- 应用是 ad-hoc 签名，没有 Apple 公证。macOS 拦截时，确认下载来源后按 [Apple 的说明](https://support.apple.com/zh-cn/102445)放行，不要关闭系统全局保护。

## 能做什么

### 四种显示方式

| 方式 | 说明 |
|---|---|
| 悬浮球 | LED 点阵小球，点一下展开成任务面板，点面板外或按 Esc 收回；可以拖到屏幕任意位置，包括紧贴边缘 |
| 常驻浮窗 | 任务面板一直显示在桌面上 |
| 刘海 | 在刘海附近显示，悬停展开；没有刘海的屏幕显示在顶部 |
| 仅状态栏 | 只在菜单栏显示数字，点开看面板 |

四种方式共用一份关注列表，右上角“＋”选任务、“⋯”切换显示方式和主题。

### 悬浮球

- 白色数字 = 在跑的任务数；琥珀色 = 等你回答或批准；红色 = 失败；绿色 = 刚完成还没看的个数。
- 有任务在跑时，外圈一道蓝光顺时针绕圈；有任务做完／开始等你／失败时，这道光原地变成绿／琥珀／红色跑两圈。没有在跑的就慢慢停下。
- 全部完成显示绿色 OK 和一段充电式庆祝；5 分钟没新任务换成慢慢呼吸的 Zz。
- 1 倍外接屏和 2 倍内置屏上点阵都对齐到像素，不发虚。

### 任务面板

- 分段显示：需要你处理 → 刚完成 → 进行中 → 已结束（可折叠）。
- 每行左边一根竖条灯表示状态，右边是等宽计时；等你和失败有标签，缺少可靠开始时间时显示 `--:--`，不瞎估。
- 同时有 Codex 和 Claude Code 任务时，每行最前面标出 CX／CC。
- 每段里按开始时间排，新的在上；任务有输出不换位置，只有状态变了（开始等你、做完）才换段。
- 点任务打开对应的 Codex 或 Claude 桌面 App。
- 底栏：左边展开／收起“已结束”，右边是 CX 本周额度和 CC 今天的 token 用量（“今天”按本机时间中午 12 点切天，熬夜到凌晨还算同一天）。点 CX 或 CC，底栏下面拉出用量卡片：额度（有 5 小时额度才显示）、今天用量和昨天比、输入／缓存／输出的构成、近 7 天柱状图。

### 设备接口

- 本机 8770 端口提供总览、任务、用量、主题和“打开任务”五个接口，Tab5 等局域网设备自动找到电脑、带 6 位口令读取，不用重复读记录。默认只有本机能读，在设置里打开局域网读取。见[接口文档](docs/REQ-005-设备读取接口/接口文档.md)。

### 关注规则

- 开着自动监控时，新开始的任务，以及重新跑起来或在等你的旧任务，都会自动加入关注；你手动移出的不会再加。
- 已结束的任务按设定天数自动移出；也可以右键“移出监控”。
- 子任务归到主任务下面。

### Claude Code

- 读本机 Claude Code 的会话记录和运行登记，桌面 App、终端里开的会话都能看到。
- 可选开关“显示‘等待你批准’”：在 Claude Code 的设置里加一条只记会话编号和时间的通知钩子（改前备份，关掉就删干净），这样等你批准权限时也能显示成琥珀色。只对打开开关之后新启动的会话生效。

## 数据与隐私

- 默认读 `~/.codex`（或 `CODEX_HOME`）和 `~/.claude`（或 `CLAUDE_CONFIG_DIR`），也可以在设置里手动选目录。
- 只读：不修改 Codex、Claude Code 的任务记录和配置（唯一例外是你主动打开的钩子开关）；不上传任何内容；不读认证文件。
- 状态来自本机已写下的记录，不是实时进程状态。在跑的任务 15 分钟没有新动静显示“状态未知”；远程机器上跑的任务（比如经 SSH 连接的项目）记录不在本机，看不到。
- 用量是按本机记录里的 token 数统计的；Claude Code 走网关时没有套餐上限，所以只显示用了多少。

## 本地构建

需要 macOS 14+ 和 Xcode（Swift 6）。

```sh
swift test
bash scripts/build-app.sh
```

构建出的 `dist/Codex Top.app` 读真实任务。只想看示例界面：

```sh
bash scripts/build-app.sh --demo
```

`dist/Codex Top Demo.app` 用独立设置和合成任务，不读本机数据。通用包、DMG 打包和诊断工具见[开发说明](docs/development.md)。

## 跨平台：Qt 版（开发中）

为了同时支持 Mac 和 Windows，正在把应用迁移到 Qt 6（C++ + QML），代码在 [`qt/`](qt/)，进度见 [REQ-004 任务总览](docs/REQ-004-Qt跨平台迁移/tasks/progress.md)。

- 已完成：技术验证（悬浮球在 Mac 两种屏幕和 Windows 11 上都清晰、不抢焦点、空闲不占 CPU），[验证记录](docs/validation/qt-m0-20261111.md)。
- 进行中：数据层搬迁。之后是界面、平台差异和并行试用；Qt 版功能追平后，Mac 原生版停止更新（届时手机连接暂停）。
- 仓库里 `windows` 分支上的 C#／WPF 版不再继续开发。

## 文档

- [使用说明](docs/usage.md) · [开发与打包](docs/development.md) · [文档入口](docs/README.md) · [当前状态](docs/STATUS.md)
- 需求与设计：[任务监控](docs/REQ-001-任务监控/requirement.md) · [Claude Code 兼容](docs/REQ-003-Claude-Code兼容/requirement.md) · [Qt 跨平台迁移](docs/REQ-004-Qt跨平台迁移/requirement.md)

欢迎在 [Issues](https://github.com/BuTangTang/Codex-Top/issues) 反馈或提 Pull Request。反馈时请写清 macOS、Codex／Claude Code 版本和复现步骤，不要上传原始 `.codex`、`.claude`、认证文件或含私人内容的截图。

Copyright © 2026 BuTangTang。使用 [GNU GPL v3](LICENSE) 许可证。独立社区项目，与 OpenAI、Anthropic 没有官方关联。
