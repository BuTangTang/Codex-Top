# Windows 集成说明 / Windows integration notes

以下记录初始 Windows 0.1.8 源码导入。当前 Windows 修订为 0.1.11，无运行任务时圆环显示 0；保留自动完成信息卡、短暂完成动效与上缘小感叹号修复；这些后续改动见 [PROJECT.md](PROJECT.md) 和 [VALIDATION.md](VALIDATION.md)，不属于最初逐字节导入的范围。

## 范围与来源

本次将已有的 Windows 0.1.8 开发预览作为独立 `windows/` 工程加入 Codex Top。按 L2 处理目录迁移与构建集成，不改变应用行为、数据协议或偏好结构。产品目标与设计见 [PROJECT.md](PROJECT.md)，使用与构建见 [Windows README](../README.md)。

- Windows 来源：[white-st/Codex_Monitor](https://github.com/white-st/Codex_Monitor/tree/26cd1c2c9d2f7d4e265749f61f3e77ce5aa587fe)，提交 `26cd1c2c9d2f7d4e265749f61f3e77ce5aa587fe`。
- Windows 最初参考的 macOS 基线：`43842fcc8489e39894508427d757c81f14866ce6`，v1.0.0 build 11。
- 本次集成的上游基线：`d31cd9f9aa982f2f2566c9c32c85e2e36b319943`，v1.0.0 build 27。
- 保留 GPL-3.0、原作者和图标来源，详见 [NOTICE.md](../NOTICE.md)。

本次保留 Windows 源码、资源、测试和构建脚本，调整使用说明与文档入口。macOS 的 `Sources/`、`Tests/`、`Resources/`、`Package.swift` 和根目录 `scripts/` 不作修改。两个平台独立构建，Windows 的 SDK 约束、输出与忽略规则位于 `windows/` 内，不引入根目录 .NET SDK 配置。

## 平台差异

| 项目 | Windows 0.1.8 | macOS build 27 |
| --- | --- | --- |
| 界面技术 | C# / WPF，Windows Forms 托盘 | SwiftUI / AppKit，系统状态栏 |
| 构建环境 | Windows 11 x64、PowerShell 7、.NET 10 SDK、Git | 见根目录 macOS 构建说明 |
| 比例 | 60%–120%，原 Windows 基准 | 80%–120%，新 100% 等于旧 75% |
| 任务移出 | 任务行右侧 `×` 取消关注 | 右键移出与选择器批量取消当前结果 |
| 结束列表与额度 | 独立折叠行和额度行，保留原 Windows 布局 | 紧凑单行结束任务与合并底栏 |
| 结束任务整理 | 手动取消关注，未移植过期自动移出 | 默认自动移出 7 天无活动的已结束任务，可调整或关闭 |
| 主题 | 手动选择深色或浅色 | 深色、浅色、跟随系统 |
| 系统集成 | 右下角托盘、PerMonitorV2 DPI、无任务栏入口 | 刘海与菜单栏、macOS 原生窗口服务 |

Windows 保留圆环悬停放大、透明圆角、深浅主题、外部点击收起、四模式共享列表，以及只读任务与独立额度刷新。此贡献不声明已移植 build 12–27 的全部后续改动。Windows 的版本号与 macOS 构建号分别维护。

## 验证与限制

本次目录迁移的构建、测试及打包结果记录在 [VALIDATION.md](VALIDATION.md) 顶部。旧版本记录按各自的日期、实现与显示器配置保留；历史的 310 项窗口检查、14 项行内移出检查不作为本次重新执行的结果。

Windows 10、ARM64、WSL、物理显示器拔插、休眠恢复和完整动画性能仍未全面验证。没有安装器、代码签名、开机启动或自动更新。本次仅准备源码贡献，不发布或覆盖 macOS / Windows Release 附件。

## English summary

This contribution imports the existing Windows 0.1.8 preview into an isolated `windows/` directory. Its application code, resources, tests, and build scripts are preserved from the source commit above. It uses C# / WPF / .NET 10 with a Windows Forms tray icon; the macOS implementation and build pipeline remain unchanged.

From the repository root, open PowerShell 7 on Windows 11 x64 with Git and the .NET 10 SDK available:

```powershell
cd windows
./scripts/build.ps1 -Publish
```

This runs the core checks, builds the app, and creates a self-contained win-x64 portable ZIP plus a separate Windows source archive under `windows/artifacts/`. Window interaction checks are opt-in with `./scripts/build.ps1 -WindowTests` and require an interactive desktop; they use isolated synthetic data.

The Windows app was initially based on macOS build 11 and does not claim feature parity with build 27. In particular, it keeps its 60%–120% scale, separate finished-task and usage rows, and an inline unfollow button. Windows checks and historical UI evidence are documented separately from macOS validation. No Windows release asset is published by this contribution.
