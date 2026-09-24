# 手机、云端与电脑协议增量

2026-09-23，主管整理的候选协议，尚未向各端下发实施。用户随后要求优先评估开源软件、避免重复造轮子，因此本协议不作为继续自研的指令。保留用于比较能力缺口；实现与真实验收尚未完成。

## 能力与目录

- 电脑同步 projects：`{id,name,canCreate}`；项目 ID 仅映射电脑配置的授权目录，手机不提交路径。
- conversations 沿用任务字段并增加 `projectId`、`canSend`、`sendUnavailableReason`。缺少 canSend 按 false 处理；联网不等于能发送。
- 原因码：`unsupported_session`、`computer_offline`、`capability_unavailable`；未知原因使用通用“当前对话暂不可发送”。服务端也必须拒绝向不可发送会话新建指令。
- 小目录可用完整 conversations 数组；大目录通过 sync 的 `conversationPage:{revision,offset,complete,items}`，每页最多 200 项。同一 revision 顺序累积，重复页内容相同可重试，冲突拒绝；只有 complete 且连续完整时原子替换生效。半页或半批不撤销旧授权。失联状态仍由心跳判断。
- revision 是电脑生成的不可复用批次标识；完成或废弃的旧批次不能覆盖新目录。服务端有界清理未完成暂存，并拒绝跨来源复用。
- 每账号目录最多 10000 个会话、500 个项目，超限明确报错，不静默裁切。
- snapshot 支持 `conversationAfter` 不透明游标；返回每页最多 100 个 conversations 和 `conversationCursor`（末页 null）。游标绑定账号和目录版本，版本失效明确拒绝并由手机重载首页；分页期间不得将未读取页当作删除。
- tasks 保持监控子集的原含义；projects、creations 是独立集合。

## 来源历史按需读取

- 复用现有 GET messages，出现 `sourceBefore` 查询参数才请求来源历史；空字符串表示来源首页，不带此参数只读取云端消息。
- 响应新增 `sourceHistory:{requestId,status,sourceBefore,olderCursor,messages}`，status 为 `pending|ready|unavailable`。pending、unavailable 不能显示为“没有历史”。
- 来源消息为 `{id,role,text,createdAt,origin:source_history}`，ID 必须稳定；正文只包含面向用户的 user/assistant 消息，不上传推理、工具调用和工具输出。
- sync 返回 `historyRequests:[{id,threadId,sourceBefore,limit:100}]`，接收 `historyResults:[{id,status:ready|unavailable,messages,olderCursor}]`。统一使用 historyRequests，不使用 historyCommands。
- 同账号、电脑、会话与游标的 pending 请求复用 ID；纯读取可重发，执行消息不可因此重发。
- 每页最多 100 条且序列化页最多 128 KiB，必须按实际字节数缩页并正确返回下一游标。单条超限不能静默截断成完整消息，应明确 unavailable。
- 来源游标由电脑生成并校验会话归属；服务端校验请求与来源、授权、结果对应。仅保存用户请求页，结果最长保留 24 小时；限流及有界队列避免轮询无限建请求。
- 来源历史与云端消息分列；手机不得仅按正文去重。无稳定关联证据时不合并来源消息与云端发送回执。

## 创建与首条消息

- 唯一新增入口：`POST /api/mobile/v1/conversations`，body 为 `{id,sourceId,projectId,text}`。
- 创建记录返回 `{id,sourceId,projectId,state,threadId,createdAt,updatedAt,initialMessageId,initialMessageState}`。threadId、initialMessageId 在未创建时为 null，initialMessageState 为 null。
- state 统一为 `server_received|dispatching|computer_received|created|uncertain|failed|cancelled|expired`；created 只证明实际 Codex 会话已创建。
- 账号内 ID 持久幂等；相同 ID 不同目标或内容返回 409。创建不确定不能自动再次创建。
- sync 返回 creationCommands，上传 `creationReceipts:[{id,state,threadId?}]`。电脑可报告 `computer_received|created|uncertain|failed`。
- created 回执必须携带真实会话 ID，且同时提供该会话的授权及项目关联。服务端不得猜测会话 ID，创建执行器不得顺带发送首条正文。
- 服务端在接受 created 的同一事务中创建唯一首条普通消息，ID 为 `creation-` 加创建请求 ID 的 UTF-8 SHA256 小写十六进制；该命名空间禁止普通手机发送接口自行占用。
- 首条消息沿用普通消息指令与回执链，initialMessageState 动态反映对应消息状态。只有真实 turn/start 接受才允许 codex_received。重复 created 回执不能增加第二条输入。
- 手机通过 snapshot.creations 追踪创建，拿到真实 threadId 后进入对应会话；首条输入状态单独显示，不将 created 显示成首条发送成功。
- 最小固定错误码：`computer_offline`、`project_unavailable`、`creation_id_conflict`、`creation_quota`、`conversation_read_only`；未知错误不解释为成功或允许换 ID 自动重试。

## 联调验收

必须覆盖：不同电脑同名会话隔离、半批目录不撤权、目录版本切换、来源历史多页及断网、只读会话拒发、重复创建与未知创建结果、创建成功而首条失败、通知直达对应会话。合成通过与真实 Codex、真机、公网验收分别记录。
