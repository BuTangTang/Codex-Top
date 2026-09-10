# 任务与用量跳转核对

核对日期：2026-09-10。依据本机已安装桌面应用 **26.903.61454** 的公开包内容和官方文档；包显示为 ChatGPT，bundle identifier 为 `com.openai.codex`。本记录不包含真实任务 ID、对话内容或认证数据。

## 路由结论

| 入口 | 使用的地址 | 核对结果 |
| --- | --- | --- |
| 点击任务 | `codex://threads/{UUID}` | 安装包明确解析为对应本地对话；可保留此路径。 |
| 点击额度 | `https://chatgpt.com/codex/settings/usage` | 应用自带常量与官方文档均指向此用量网页；界面应明确标注“网页”。 |
| 外部原生用量深链 | `codex://settings/usage` | 此版本不支持精确导航，会降为设置首页，不能作为用量页入口。 |

`Contents/Info.plist` 注册 `codex` scheme。只读调用 `NSWorkspace.urlForApplication(toOpen:)` 确认，系统当前 handler 就是上述 `com.openai.codex` 应用；该查询没有打开应用。实现可通过 bundle identifier 定位应用，再用带完成回调的 `NSWorkspace` 打开任务链接，处理应用缺失或系统打开失败。

## 安装包依据

下列路径均相对于 `Contents/Resources/app.asar`，符号名仅对应本次检查的版本：

- `.vite/build/window-all-closed-BKkx4ypf.js`：`yD` 的 `threads` 分支产生 `localConversation`；`lD` 为可直接打开的设置子页白名单，未包含 `usage`；`CD` 对非白名单子页返回普通 `settings`。
- `.vite/build/src-J2PvP4xj.js`：`_E`/`DE` 校验 `codex:`、`threads` 与 UUID；`EE` 生成内部 `/local/{UUID}` 路由。
- `.vite/build/main-D87AK7lw.js`：`nIe` 的 `localConversation` 分支先读取对应线程，再导航至该对话。系统接受 URL 不代表此读取及页面导航已经成功。
- `webview/assets/app-primary-e25aaf15dbaf.js`：存在内部 `/settings/usage` 导航，但内部路由存在不等于外部 scheme 允许该路径。
- `webview/assets/app-initial-1b87ae739476.js`：`eg` 为 `https://chatgpt.com/codex`，`UEi` 为 `${eg}/settings/usage`。

[官方 Pricing 文档](https://learn.chatgpt.com/docs/pricing#where-can-i-see-my-current-usage-limits) 的当前用量说明链接到同一用量网页。该页面属于 ChatGPT/Codex 用量入口，不是 OpenAI API 用量面板。

## 验收边界

- 最初的路由核对只读检查包内容、URL handler 和官方文档；未打开 Codex 窗口，未进行真实任务跳转或网页终点验收。后续实际应用操作的证据与边界见 D-32。
- 用户已反馈当前“不闪、正常”。这是用户对当前使用效果的确认，不是全平台、逐帧或 FPS 验收结论。
- 原独立 QA 应用保持关闭；D-30 / D-31 交付记录仅操作旧 Demo 退出、真实应用启动及调试服务清理，没有重新进行 D-29 截图验收。
- 外接屏物理切换、不同系统版本及应用升级后的路由兼容性，不能由本次源码核对替代。

## D-30 / D-31 历史构建与桌面交付检查点

2026-09-10 完成当时的 `scripts/package.sh --universal`：48 项测试（24 核心、12 几何、2 状态、2 跳转、8 额度），实际应用 arm64/x86_64 release、Info.plist 检查、严格签名及 ZIP 完整性通过。该轮没有重新构建新版 Demo。以下产物是历史检查点，已由下方 D-32 产物替代。

| 历史产物（D-30 / D-31） | SHA-256 |
| --- | --- |
| `Codex-Top-0.1.0-dev-macOS.zip` | `1634b552d2a737575a5cc8d2a73147445e489b943583dfee51125c3e3788d29e` |
| 实际应用可执行文件 | `c55fbaa4d72353d783f2ad77e370d949a25ec51c301817e359597c5a8973bf5f` |

- 通过生产额度客户端完成一次真实读取，接口返回周窗口，未返回的 5h 窗口保持缺失。公开材料不记录用户实际比例、真实任务名称或 ID；原始诊断保留在被忽略的本地目录。
- 通过生产任务读取路径确认本机真实任务可读取，无变化的紧接刷新读取 0 字节。这是数据层证据，不是本轮 UI 内容截图。
- 将最终实际应用复制到桌面 `Codex Top.app`；严格签名通过，二进制与构建产物 SHA-256 一致。备份实际偏好后仅迁移浅色、80% 比例、菜单栏模式及窗口位置，保留真实任务选择/排除/自动加入规则与数据来源。
- 通过活动监视器正常退出旧 Demo，进程检查确认结束；桌面两份旧 Demo 移入本地备份，防止继续误开演示任务。通过 CUA 启动真实应用，进程及活动监视器均确认真实应用运行。
- CUA 获取真实菜单栏应用窗口超时；没有取得本轮任务/额度窗口画面，也没有完成 D-31 左键开合、右键菜单、80/90/100 比例原生视觉验证。进程运行不代替这些验收。
- 本次始终由根代理操作桌面；收尾通过活动监视器退出 Computer Use 提示服务，进程检查确认该服务不再运行。未再次启动服务抓图证明清理。

D-31 将菜单栏弹层与顶部 hover 分离：窗口固定为完整缩放后的尺寸，仅执行 0.96↔1 的 scale 与淡变；关闭结束后隐藏窗口，不保留 44×22 黑色端点。状态按钮转换为屏幕坐标，移开指针不自动收起，快速切换取消旧关闭任务。其源代码及构建已经核对，原生实机边界保持如上。

## D-32 任务跳转崩溃修复与验证

### 崩溃原因与修复

真实应用点击任务后发生 `SIGTRAP`，故障队列为 `com.apple.launchservices.open-queue`，关键调用栈为 `_dispatch_assert_queue_fail` → `swift_task_isCurrentExecutorWithFlagsImpl` → `closure #1 in TaskStore.openTask`。`NSWorkspace` 的外层完成回调继承了 `MainActor` 隔离；Launch Services 从后台队列调用时，在进入闭包正文、执行内部 `Task { @MainActor in … }` 之前就触发执行器断言。

修复位于 `Sources/CodexTop/TaskStore.swift` 的 `openTask`：将外层完成回调显式标为 `@Sendable`，内部处理界面状态的 `Task { @MainActor in … }` 保持不变。这样系统回调可从后台队列进入，界面状态仍交回主 actor 更新。

最小实验提取生产回调结构，以后台队列模拟系统调用，使用 `swiftc -swift-version 6 -enable-actor-data-race-checks` 编译：旧写法子进程退出码为 `-5`，新写法退出码为 `0`，并确认主 actor 回调成功。最初未启用 actor 数据竞争检查的实验没有复现，不作为支持修复的验证证据。

### 构建产物

修复后 48 项测试通过，实际应用 universal release 重新构建通过。桌面副本与构建产物可执行文件的 SHA-256 一致。

| D-32 产物 | SHA-256 |
| --- | --- |
| `Codex-Top-0.1.0-dev-macOS.zip` | `87c4f12248db637289da09882f9b4c3f21bb85c2161f18a8746d1b68d0acaa1d` |
| 实际应用可执行文件及桌面副本 | `1c05eef403a68adbe5e7b4f69e56929ad027d03bed6f72de559920760d06ae76` |

### 实际应用证据与剩余边界

- 根代理通过 CUA 在真实包中看到本机关注任务、额度，以及未返回 5h 窗口的提示。点击真实任务后，面板正常收起，原进程仍运行，未出现新的 `CodexTop` 崩溃记录；未读取 Codex 对话终点，因此不把调用成功与应用存活等同于对应对话已经导航成功。
- 在设置中恢复“仅状态栏”与 80% 比例，关闭设置后使用 `Cmd+T` 触发与状态栏按钮共用的 `showTasks` 路径。原生辅助功能信息及截图显示完整面板、真实关注任务和额度，窗口图像约为 328×118，按比例排版，没有留下小黑块。
- 点击额度区域后，CUA 返回 `noWindowsAvailable`，符合成功调用后关闭并隐藏面板的行为。没有完成用量网页终点验收；Edge 标签页查询超时，不能据此声称网页已正确打开。
- 额度操作后的最终核对确认，同一真实应用进程仍运行，设置已恢复为仅状态栏、浅色、80%。根代理通过活动监视器退出单个 Computer Use 提示服务，确认该服务进程消失、实际应用继续运行。
- 系统状态栏图标的实际左键、右键操作，以及 90% / 100% 比例仍待验收。`Cmd+T` 只验证共用 `showTasks` 路径，不能代替状态栏图标点击。
- 本轮截图含用户信息，只保留在工具上下文，不提交 Git；公开材料不记录真实标题、任务 ID、额度比例或私有绝对路径。本次验证不构成所有屏幕、系统版本或 FPS 的验收结论，也未重新进行 D-29 专项玻璃截图验收。
