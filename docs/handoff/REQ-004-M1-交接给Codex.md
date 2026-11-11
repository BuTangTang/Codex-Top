# REQ-004 M1 数据层：交接给 Codex

2026-11-11 用户决定把 REQ-004（Qt 跨平台迁移）的 M1 交给 Codex 做。本文件是交接说明，最后一节是直接贴给 Codex 的提示词。

## 1. 现在做到哪了

- 需求、设计、任务都已通过：[需求](../REQ-004-Qt跨平台迁移/requirement.md)、[设计](../REQ-004-Qt跨平台迁移/detailed-design.md)、[任务总览](../REQ-004-Qt跨平台迁移/tasks/progress.md)、[M1 清单](../REQ-004-Qt跨平台迁移/tasks/M1-数据层.md)。
- M0 技术验证已通过：[验证记录](../validation/qt-m0-20261111.md)。
- M1 已开头：`qt/core/models/` 已把原生版 `Models.swift` 搬成 C++（任务模型、七种状态、额度、错误文字、时间解析）；`qt/CMakeLists.txt` 已把数据层拆成几个模块库，Mac 上编译通过。其余模块目录是空的，等你填。

## 2. 工程结构（已经搭好，照着填）

```
qt/core/models/   任务模型（已完成）
qt/core/led/      悬浮球排版（M0 已完成）
qt/core/codex/    读 Codex：状态库、任务记录、压缩记录、文件变化监视、桌面回执
qt/core/claude/   读 Claude Code：会话记录、运行登记、钩子事件、钩子安装
qt/core/policy/   关注规则、任务图、偏好、状态汇总
qt/core/usage/    额度（codex app-server）、Claude／Codex 用量统计
qt/tests/<模块>/test_*.cpp   每个文件一个 Qt Test 程序，自动链接同名模块库
```

- 每个模块是 `qt/core/<模块>/` 下全部 `.cpp` 编成的静态库，只依赖 QtCore（codex 另加 Qt Sql 和 zstd）。新增文件不用改 CMake。
- 模块之间需要互相依赖时，在 `qt/CMakeLists.txt` 里 `codextop_core_module(...)` 那一行追加依赖。
- 压缩记录用的 zstd 已接好（复用 `Sources/CZstd/vendor`，目标名 `codextop_zstd`，已链给 codex 模块）。

## 3. 环境

| | Mac（本机） | Windows（butang-windows） |
|---|---|---|
| Qt | `/Users/butang/Developer/toolchains/pvtc-qt/Qt/6.11.2/macos`（PVTC 的，只读使用，不要改） | `D:\soft\Qt\6.11.2\msvc2022_64` |
| 编译器 | Xcode clang、`/opt/homebrew/bin/cmake`、`ninja` | VS 2022 Build Tools（VS 2026 没装 C++，脚本会自动跳过） |
| 编译 | `cmake -S qt -B qt/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<上面的 Qt>`，然后 `cmake --build qt/build`，`ctest --test-dir qt/build --output-on-failure` | 代码放 `D:\soft\Qt\codex-top-qt`，跑 `packaging\windows\build.bat`（ASCII + CRLF，别加中文） |
| 连接 | — | `ssh butang-windows`，登录后是 Git Bash；`hostname` 输出小写 `butang`、`COMPUTERNAME=BUTANG` |
| 磁盘 | 只剩约 16 GiB，不要再装第二套 Qt | D 盘约 19 GiB |

## 4. M1 要做的事（对应 M1 清单 T1.1～T1.12）

原生版 Swift 文件和测试 → Qt 版位置：

| Qt 模块 | 搬哪些 Swift 文件（`Sources/CodexTopCore/`） | 测试要逐条搬的（`Tests/CodexTopCoreTests/`） |
|---|---|---|
| codex | `RolloutReducer`、`RolloutTimingRecovery`、`ToolActivityText`、`QuestionReplyReceipt`、`LocalCodexSource`、`CompressedRolloutReader`、`RolloutChangeMonitor`、`DesktopReplyReceiptSource` | `IncrementalRollout*`、`Recovery`、`ToolActivityText`、`QuestionReply*`、`ReplyContinuation`、`LongWaitReply`、`WaitingDuration`、`LocalCodexSource*`、`CompressedRollout`、`RolloutChangeMonitor`、`DesktopReplyReceiptSource`、`CoreTests` 里属于读取的部分 |
| claude | `ClaudeTranscriptReducer`、`ClaudeSessionRegistry`、`ClaudeCodeSource`、`ClaudeHookEvents`、`ClaudeHookInstaller`（以及 `Sources/CodexTopClaudeHook` 小程序，放 `qt/helper/`） | `ClaudeCodeSource`、`ClaudeTimestamp`、`ClaudeHook` |
| policy | `MonitoringPolicy`（含偏好、任务图、偏好文件）、`MonitorStatusSummary`、`CompactMonitorSummary`、`MonitorScale` | `CoreTests` 里属于关注规则的部分、`FinishedRetention`、`MonitoringGraphReuse`、`TaskGraph*`、`TaskListPreferences`、`PlacementHistory`、`MonitorStatusSummary`、`CompactMonitorSummary`、`MonitorScale`、`Navigation`、`PendingNavigation` |
| usage | `AccountUsageClient`、`AccountUsageProtocol`（用 QProcess 启动 `codex app-server --stdio`）、`ClaudeUsageCounter`、`CodexUsageCounter` | `Quota`、`ClaudeUsageCounter`、`CodexUsageCounter` |
| led | 已完成；补测试 | `LEDOrbLayout` |

不搬：`MobileAccountClient`（手机连接，第一版不带）、`WindowGeometry`（界面层，M2 再搬）。

**结果对齐（T1.1，必须做）**：
1. 上表“测试要逐条搬的”全部逐条搬成 Qt Test：同样的合成输入、同样的期望值、同样的中文文字。原生版测试改不了的期望值就是标准答案。
2. 另外给原生版的检查工具 `Sources/CodexTopInspect` 加一个导出命令（只是开发工具，不改 App 任何行为），把一批合成的 Codex 任务记录和 Claude 会话记录，以及原生版对它们算出的状态（阶段、文字、各个时间）导出到 `qt/tests/fixtures/`；Qt 版测试读同一批文件比对。样例只能是合成数据。

## 5. 规矩（照做）

- **规则一字不改**：判断规则、阈值、中文提示文字都照原生版；发现原生版有疑似问题，记下来问用户，不要顺手“改好”。
- **只读**：不写、不改 Codex 和 Claude 的任何数据文件；测试只用合成数据和临时目录，不读真实 `~/.codex`、`~/.claude`。
- **不动原生版**：`Sources/` 下除了 T1.1 的导出命令，什么都不改；不打原生版的包、不装。原生版另有会话在维护，构建号也别占。
- **提交**：只 `git add` 自己改的文件，不要 `git add -A`；提交前看 `git status`，有不认识的改动先问用户。提交说明英文，结尾加你自己的署名行。拉取、推送前先问用户。
- **Qt 版不加新功能**：只搬现有的。
- **文档**：做完一个模块就勾 [M1 清单](../REQ-004-Qt跨平台迁移/tasks/M1-数据层.md) 并在后面写一句结果；M1 全部完成时写 `docs/validation/qt-m1-<日期>.md`，并在 `docs/STATUS.md` 最上面加一条。
- **和用户说话**：中文、口语化、先说结论；遇到要用户拍板的事先问，不要自己定。
- **完成标准**：Mac 上 `ctest` 全部通过；Windows 上 `build.bat` 编译通过、`ctest` 全部通过；验收记录写清楚搬了多少条测试、有没有跳过的和原因。

## 6. 直接贴给 Codex 的提示词

```
你接手 Codex Top 仓库（/Users/butang/Developer/myproject/Codex-Top/Codex-Top）里 REQ-004 Qt 跨平台迁移的 M1 数据层。

先按顺序读完：
1. docs/handoff/REQ-004-M1-交接给Codex.md（本次交接的全部要求，以它为准）
2. docs/REQ-004-Qt跨平台迁移/requirement.md、detailed-design.md、tasks/M1-数据层.md
3. AGENTS.md、docs/STATUS.md 最上面几条

任务：把原生版 Sources/CodexTopCore 的数据层逐个搬成 C++，放进 qt/core/<模块>/；把交接文档第 4 节列出的原生版测试逐条搬成 Qt Test，放进 qt/tests/<模块>/test_*.cpp；再给 Sources/CodexTopInspect 加一个导出合成样例和原生版结果的命令，输出到 qt/tests/fixtures/，Qt 版测试读它比对。

顺序：codex → claude → policy → usage → led 补测试 → 导出样例对齐 → Windows 编译和测试 → 验收记录。每做完一个模块：Mac 上编译、ctest 全过，再勾 M1 清单、本地提交（只加自己的文件），然后做下一个。

硬性要求：
- 判断规则、阈值、中文文字一字不改；觉得原生版有问题就记下来问用户，不要改。
- 不读真实 ~/.codex、~/.claude，测试只用合成数据和临时目录。
- Sources/ 下只允许加导出命令，其他原生版代码一律不动，不打原生版的包。
- 不要 git add -A；push 和 pull 前先问用户。
- Mac 上用 /Users/butang/Developer/toolchains/pvtc-qt/Qt/6.11.2/macos 这套 Qt，不要再装 Qt；Windows 用 ssh butang-windows，Qt 在 D:\soft\Qt\6.11.2\msvc2022_64，用 qt/packaging/windows/build.bat 编译。
- 和用户用中文、口语化交流，先说结论。

第一步：读完上面的文件后，用三五句话告诉用户你对任务的理解和打算的顺序，等用户说开始再动手。
```
