# Codex Top 中转服务（开发中）

独立账号、来源快照与文字消息中转。只访问指定 SQLite 文件，不读取 Codex 数据、宿主目录、PVTC 数据库或 Docker 状态。当前已通过合成客户端 HTTP 测试，尚未对接安卓聊天页、真实电脑执行器或阿里云，不能作为已上线产品使用。

## 本地运行

需要带 OpenSSL scrypt 的 Python 3.12 或更新版本，无第三方 Python 包。macOS 自带的部分 Python 3.9 构建缺少 scrypt，本轮使用独立 Python 3.12.14 验证，不更改系统 Python。

在仓库根目录执行，数据库放在 Git 忽略目录：

```sh
python3 -m relay.server --database .local/relay/data.sqlite add-account your-account
python3 -m relay.server --database .local/relay/data.sqlite add-device your-account mac-main "MacBook Pro"
python3 -m relay.server --database .local/relay/data.sqlite serve
```

第一步隐藏输入密码；第二步仅一次输出电脑专用令牌，应放入该电脑的安全存储，不发到聊天或提交 Git。账号和设备均由管理员本机创建，没有公开注册、扫码或设备管理 API。重复创建会拒绝，不覆盖旧身份。

服务默认监听 `127.0.0.1:18766`，不会占用旧合成服务 18765 或 PVTC 8088。调试安卓可以对该端口使用 USB 转发，但这不证明公网互通。已提供[独立 Docker 配置与运维步骤](deploy/README.md)，部署到阿里云前仍需容器实际运行、独立 HTTPS 入口、备份/恢复和实际跨网验收，不直接开放此明文监听到公网。

## 必要接口

| 方法与路径 | 调用方 | 用途 |
|---|---|---|
| POST `/api/mobile/v1/sessions` | 手机 | 沿用 username/password 登录，返回 token/account |
| DELETE `/api/mobile/v1/sessions/current` | 手机 | 撤销本次登录 |
| GET `/api/mobile/v1/snapshot` | 手机 | 复用来源与任务快照，同时作为授权会话列表来源 |
| GET `/api/mobile/v1/conversations/{source}/{thread}/messages?before={cursor}` | 手机 | 对话消息，分页游标可省略 |
| POST `/api/mobile/v1/conversations/{source}/{thread}/messages` | 手机 | `{id,text}`，ID 必须在重试时保持不变 |
| POST `/api/desktop/v1/sync` | 电脑 | 完整授权 tasks、receipts、replies 上报，返回 commands |

除登录外均使用 Bearer 令牌。电脑令牌绑定账号和单个来源，不能代手机发消息，不能向别的电脑会话上报回复。手机令牌不能发布来源状态或伪造电脑回执。来源名称不参与路由；同名会话按来源 ID 和会话 ID 区分。

电脑 sync 的 tasks 沿用安卓现有 Task 字段，sourceId 由服务绑定而不是信任上传字段；仅在成功读取本机来源时提交新的完整快照。未出现的会话立即撤销共享，取消尚未派发输入。receipts 为 `{id,state}`；replies 为 `{id,threadId,text}`，回复事件 ID 必须由电脑持久保留，不能每次轮询随机生成。同步按上报、回执、回复、最后领取执行输入的顺序处理，整批使用同一事务；任意事件失败时回滚全部快照、回执、回复和领取。客户端重试必须保留原消息/回复 ID。

## 状态与失联

- `server_received`：仅服务持久接收，还未交给电脑。
- `dispatching`：正在派发；HTTP 响应可能尚未被电脑收到。
- `computer_received`：电脑明确确认收到。
- `codex_received`：电脑取得真实 Codex 接受证据后才能上报；此状态不代表任务完成。
- `uncertain`：派发或电脑收到后一分多钟没有进一步确认。禁止自动重投输入；电脑应先核对自己的持久发送日志和 Codex 接收证据。
- `failed` / `cancelled` / `expired`：已失败、共享撤销或未领取超时、正文过期；原 ID 不会重新执行。

电脑心跳超过 60 秒时拒绝新输入。未领取输入超过 60 秒取消；领取响应丢失不会自动再次领取，因此当前策略优先避免重复执行，但不承诺每条输入必然送达。真正的恢复体验仍需电脑执行器和手机状态界面配合，不能将此标记为端到端可靠投递已完成。

正文暂按 24 小时逻辑保留，每分钟维护清理并截断本数据库 WAL；备份保留期尚待部署设计，不能将数据库清理描述为所有副本物理销毁。消息 ID 和正文摘要保留用于去重，每账号最多 10000 条，达到上限明确拒绝新消息；当前没有自动删除幂等记录或管理清理接口。会话令牌 7 天到期，每角色最多 128 个有效令牌；管理员 CLI 已提供 rotate-device、revoke-device 和 revoke-mobile-sessions，流程见部署文档。自动续期仍未实现。

登录按连接来源每分钟 10 次尝试限流，最多 16 个并发连接、最多 2 个同时密码运算、10 秒连接超时、256 KiB 请求体。反向代理后连接来源可能共享同一额度；部署阶段应在可信入口补客户端限流，不能盲目信任 X-Forwarded-For。对话历史每页最多 100 条且正文 JSON 预算 512 KiB，达到预算时沿用 olderCursor 翻页，避免超过手机响应上限。未启用跨域浏览器访问，也不代理任意 Codex 方法或命令。

## 验证

```sh
python3 -m unittest discover -s relay/tests -v
```

全部数据、账号与回复均为合成，测试随机本机端口和独立临时目录。存储测试覆盖账号/角色隔离、多电脑同名会话、并发领取、服务重启去重、离线/共享撤销、派发结果不确定、回复去重、分页及过期清理；HTTP 测试覆盖真实请求闭环、注销、错误输入、角色与登录限流。通过这些测试不代表真实 Codex、手机锁屏或公网部署验收通过。
