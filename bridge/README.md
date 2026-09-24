# 电脑中转适配器（接入未完成）

本目录实现电脑 → relay 的单一 `/api/desktop/v1/sync` 出站客户端和独立发送账本。**当前没有可用的真实 Codex 执行器**，不能声称手机输入已进入电脑会话。`python3 -m bridge` 明确退出 2，既不连接桌面，也不向 relay 发布空快照。

## 已实现

- `RelayClient`：HTTPS、10 秒超时、256 KiB 请求/响应限制，拒绝所有重定向；显式调试仅允许数字 loopback HTTP。凭据不出现在 URL 或日志。
- `Journal`：独立 SQLite、0600 权限、进程锁、身份绑定、发送前持久化。仅保存输入正文摘要；同一输入 ID 即使重启或超时也不重发。可能牺牲送达，不能宣传 exactly-once 或必达。
- `Bridge.step()`：只同步执行器明确授权的完整任务列表，授权读取失败不冒充空列表。未知线程拒绝。执行器必须在真正提交前再次验证本地授权、会话所属实例和活动轮次。
- 只有输入 ID、线程 ID、非空轮次及明确接受证据匹配才上报 `codex_received`，与完成状态无关。发送结果不明仅报告 `computer_received`，由服务超时变为 `uncertain`。
- 完整回复通过 thread/turn/item 稳定键去重；成功同步、授权撤销或 24 小时逻辑过期后清除待发正文。摘要保留，不是所有文件副本的物理销毁保证。
- 不启动 app-server，不修改 Codex 数据库、配置、任务或认证文件；不访问 PVTC。

## 执行器契约与缺口

调用方提供 `snapshot()`、`send(command)`、`replies()`：

1. `snapshot()` 返回 relay 已有 Task 字段列表。必须来自用户明确选择的本地已有线程。读取异常抛 `Unavailable`，用户主动清空授权才返回 `[]`。
2. `send()` 必须通过**已验证、同一桌面实例**的连接提交已有线程。成功返回 `{accepted: true, messageId, threadId, turnId}`；能证明提交前拒绝抛 `Rejected`，提交后超时或证据不足属于不确定。不能因 clientUserMessageId 字段存在就假设 Codex 去重。
3. `replies()` 返回完成且不可变的 `{threadId, turnId, itemId, text}`。不能把 token 增量当完整回复或用每次随机 ID。

已只读检查安装包存在 `thread-follower-start-turn`、`thread-follower-steer-turn` 内部分支，但未验证目标拥有者选择、请求版本、轮次竞争与成功响应证据。因此没有在代码里猜测内部写入协议，也没有添加“强制启用”开关。

下一步需要在用户明确指定的隔离测试会话，对**现存桌面实例**验证版本绑定与拥有者匹配、空闲发送、活动轮次追加、断线后接受证据、完整回复稳定 ID。若不能证明这些条件，保持禁用，不用新执行器接管原会话。

当前还缺真实授权选择入口、凭据安全存储/轮换、后台生命周期接入、完整回复接入、正文存储总量管理和真实跨网验收。账本绑定 token 摘要，轮换 token 不能直接换一个空账本继续投递；需要明确的身份迁移/待确认处理流程。不能作为已可部署电脑代理交付。

## 验证

```sh
python3 -m unittest discover -s bridge/tests -v
python3 -m bridge
```

2026-09-23：16 项专项测试通过，使用独立临时数据库、合成执行器及随机 loopback HTTP 服务；后者已验证退出 2。测试证明本机去重、传输边界与失败关闭，不证明真实 Codex 接入、阿里云、锁屏或多电脑实测。
