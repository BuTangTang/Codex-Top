# Codex 接入核验记录

## Happier 改造核验（2026-09-23）

用户已授权拉取并修改 Happier。独立源码基线为 ce5517b07e5b9ae6b340c9d6f7aa895758147bd8；其 codexDirectSessionProviderOps 已提供历史和跟随，现有 takeover RPC 会解析 spawnOptions 并调用 spawnSession。保持桌面拥有者的发送不能复用这一接管操作的语义，也不能仅开放手机按钮。应沿现有机器 RPC 与 provider owner 扩展，复用账号、中转和手机对话。

本机桌面安装包再次只读核对：thread-follower-start-turn 的 handler 调用 startTurn(conversationId, turnStart)，桌面调用端发送 turnStart:{request,context}；steer 使用独立方法。尚未提交真实输入，字段存在不等于实机兼容完成。

电脑任务报告的固定版本参考：[Remodex follower](https://github.com/Emanuele-web04/remodex/blob/e0e342dac5cddd40db661bfcf76e5ab0e3913ef8/phodex-bridge/src/desktop-ipc-action-follower.js#L2163) 使用相近 turnStart 形状，但其连接失败转本地执行路径与用户要求冲突，不能原样引入。其 fixture 验证版本不同于本机，仍需核对本机协议及隔离会话回执。Farfield 旧 turnStartParams 形状不能直接使用。参考源码和许可在真正引入前由主管复核。

Happier 开发依赖开始按 yarn.lock 安装。初次下载重复网络重试；定向 Node fetch 超时而 curl 成功，启用 NODE_USE_ENV_PROXY 后同地址返回 200，随后以该进程环境重新安装。仅改变安装进程环境，不更改系统代理或仓库锁文件。依赖安装尚未完成，不构成测试通过。

2026-09-23。只读可行性核验，尚未完成真实会话收发，不是交付验收。

## 已取得的证据

本机可执行文件报告 `codex-cli 0.155.0-alpha.16`。通过 `codex app-server generate-json-schema` 将当前版本协议导出到被忽略的本地目录，只检查类型和方法，不生成任务、不读正文。当前版本包含：

| 方法 | 核对结果 | 能证明什么 |
|---|---|---|
| `initialize` | 必须传 clientInfo | 存在客户端握手协议 |
| `thread/read` | threadId 必填，includeTurns 可选 | 存在会话读取入口 |
| `thread/resume` | threadId 必填 | 存在接续已有会话入口 |
| `thread/loaded/list` | cursor/limit 可选 | 存在已加载会话查询入口 |
| `turn/start` | threadId/input 必填 | 存在发送输入入口 |
| `turn/steer` | threadId/input/expectedTurnId 必填 | 活动轮次追加必须关联预期轮次 |

官方 [App Server 文档](https://learn.chatgpt.com/docs/app-server)说明：握手后可以恢复会话、发送输入并接收回复事件。公开文档与本机版本并不保证每个字段完全一致，适配必须以实际版本握手和协议为准。

`turn/start` 和 `turn/steer` 有 clientUserMessageId 字段，但导出的描述没有保证幂等语义。因此不能仅凭这个字段实现“超时自动重发且永不重复执行”；需要实际重复提交/重连实验，或在结果不确定时保持待确认并核对结果。

## 共享运行实例仍未证实

尝试使用现有 CLI 的 `app-server proxy` 执行握手，代理在连接默认共享控制 socket 时退出，错误为端点不存在。只启动了连接代理并清理该代理，没有启动/重启/安装 daemon，没有更改 Codex 配置、认证文件、数据库或会话。

该证据仅说明默认共享控制端点当前不可用，不表示官方协议不可用，也不表示 Codex 桌面不存在其他连接机制。不得为绕过问题自动启动另一个服务并对正在运行的真实会话执行 resume/start；独立进程有接口不等于与桌面共享同一个活动会话。

## 下一项可执行核验

确认桌面所用运行实例的受支持连接方式；随后在明确隔离的测试会话验证手机消息对应的真实接受回执、回复流、活动轮次处理和断连恢复。禁止以改写任务文件或未验证的内部 IPC 发送替代。当前仅有只读回执监听代码，不构成公开的消息写入支持。

多电脑路由必须绑定账号、来源电脑和会话；手机界面不允许全局电脑切换改变已有对话目标。通知直达同一身份的会话，至少两台电脑同名会话不串线是必要验收项。

UI 方面 A/B/C 三套多电脑设计图均已生成，正在等待用户选择。后续云端部署仍需确定真实连接目标与 HTTPS 入口；本轮未连接阿里云，也未修改 PVTC。

## 第二次核验：桌面协调入口

同日继续只读检查运行进程：实际 app-server 使用 `--listen stdio://`，默认代理 socket 不存在并非整个桌面服务未运行。对现有桌面协调 socket 使用项目已有回执读取器所用的长度前缀协议执行一次 initialize，收到 success 与 clientId，随后关闭连接；没有关注真实任务、读取正文或提交输入。

只读检查当前桌面安装包发现 `thread-follower-start-turn` 与 `thread-follower-steer-turn` 转发处理，以及已有的快照跟随机制。这支持“存在将输入转交所属窗口的内部实现”这一有限结论，不能据此证明第三方稳定支持、跨版本兼容、权限安全、幂等或已完成真实收发。

下一步必须区分两条路径：官方 app-server 协议目前已确认字段但未接上现有桌面实例；桌面协调协议已握手但属于内部兼容路径。不能把后者标成官方公开接口，也不能在未知版本继续发送。若采用该路径，须有明确版本约束、目标会话所属客户端验证、不可用时禁止发送，并先在独立测试会话验证接受回执及回复；不得自动另起执行器接管现有活动任务。本轮仍未选择或实施消息写入路径。
