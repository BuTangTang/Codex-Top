import Foundation
import CodexTopCore

/// T1.1：复用与原生回归相同的合成事件形状。所有期望逐行由当前原生归约器生成。
enum NativeFixtures {
    private typealias Row = [String: Any]
    private struct Sample {
        let name: String
        let origin: TaskOrigin
        let rows: [Row]
    }

    private static func codex(_ type: String, _ at: String? = nil, kind: String = "event_msg",
                              extra: Row = [:], ordinal: Int? = nil) -> Row {
        var payload = extra
        payload["type"] = type
        var row: Row = ["type": kind, "payload": payload]
        row["timestamp"] = at
        row["ordinal"] = ordinal
        return row
    }

    private static func claude(_ kind: String, _ at: String?, _ message: Row, extra: Row = [:]) -> Row {
        var row = extra
        row["type"] = kind
        row["timestamp"] = at
        row["message"] = message
        return row
    }

    private static func call(_ name: String, _ id: String, _ at: String, input: Row = [:]) -> Row {
        claude("assistant", at, ["role": "assistant", "stop_reason": "tool_use",
            "content": [["type": "tool_use", "name": name, "id": id, "input": input]]])
    }

    private static var samples: [Sample] {
        let start = "2027-01-15T08:00:00.900900Z"
        let older = "2027-01-15T08:00:00.900100Z"
        let wait = "2027-01-15T16:00:01.900100+08:00"
        let finish = "2027-01-15T08:00:05Z"
        let turn = ["turn_id": "synthetic-turn"]
        let prompt: Row = ["role": "user", "content": "合成输入"]
        let end: Row = ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "done"]]]
        let reply: Row = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "q1", "content": "ok"]]]
        return [
            Sample(name: "codex-lifecycle", origin: .codex, rows: [
                codex("future_event"),
                codex("task_started", start, extra: turn),
                codex("task_complete", older, extra: turn),
                codex("function_call", wait, kind: "response_item", extra: ["name": "request_user_input", "call_id": "q1"]),
                codex("function_call_output", finish, kind: "response_item", extra: ["call_id": "q1"]),
                codex("turn_failed", finish, extra: turn),
                codex("agent_message", finish),
                codex("task_started", finish, extra: ["turn_id": "second"]),
                codex("task_complete", finish, extra: turn),
                codex("turn_aborted", finish, extra: ["turn_id": "second"]),
                codex("task_started", extra: ["turn_id": "no-clock"]),
                codex("exec_approval_request"),
                codex("approval_resolved", finish),
                codex("task_complete", finish)
            ]),
            Sample(name: "codex-teamchat", origin: .codex, rows: [
                ["type": "session_meta", "ordinal": 0, "payload": ["teamchat_copy": ["automatic": true]]],
                codex("task_started", start, extra: ["turn_id": "remote"], ordinal: 1),
                codex("agent_message", wait, ordinal: 2),
                codex("thread_settings_applied"),
                ["type": "turn_context", "ordinal": 12, "payload": ["turn_id": "local"]],
                codex("task_started", wait, extra: ["turn_id": "local"], ordinal: 13),
                codex("task_complete", finish, extra: ["turn_id": "local"], ordinal: 14)
            ]),
            Sample(name: "claude-lifecycle", origin: .claudeCode, rows: [
                ["type": "custom-title", "customTitle": "合成会话"],
                claude("user", start, prompt),
                claude("assistant", older, end),
                call("Bash", "t1", start),
                call("AskUserQuestion", "q1", wait),
                claude("user", finish, reply),
                call("ExitPlanMode", "p1", finish),
                claude("user", finish, ["role": "user", "content": "[Request interrupted by user for tool use]"]),
                claude("user", finish, prompt),
                claude("assistant", finish, ["role": "assistant", "content": []], extra: ["isApiErrorMessage": true]),
                claude("user", nil, prompt),
                claude("assistant", "invalid", end),
                claude("user", finish, prompt, extra: ["isSidechain": true])
            ]),
            Sample(name: "claude-desktop-question", origin: .claudeCode, rows: [
                claude("user", start, prompt),
                call("mcp__ccd_turn__wrap_up", "w1", wait, input: ["recap": "done", "ask": "合成提问？"]),
                claude("user", wait, ["role": "user", "content": [["type": "tool_result", "tool_use_id": "w1"]]]),
                claude("assistant", finish, end),
                claude("user", finish, prompt),
                claude("assistant", finish, end)
            ])
        ]
    }

    /// 导出顺序、时间和编码固定。同一版原生代码反复运行会得到相同字节。
    static func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sample in samples {
            var rollout = RolloutReducer(), transcript = ClaudeTranscriptReducer()
            var inputs = Data(), expected = Data()
            for row in sample.rows {
                let line = try json(row)
                let activity: TaskActivity
                switch sample.origin {
                case .codex:
                    rollout.consume(line)
                    activity = rollout.activity
                case .claudeCode:
                    transcript.consume(line)
                    activity = transcript.activity
                }
                inputs.append(line)
                inputs.append(10)
                expected.append(try json(snapshot(activity, origin: sample.origin)))
                expected.append(10)
            }
            try inputs.write(to: directory.appendingPathComponent(sample.name + ".input.jsonl"), options: .atomic)
            try expected.write(to: directory.appendingPathComponent(sample.name + ".expected.jsonl"), options: .atomic)
        }
    }

    private static func json(_ value: Row) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func snapshot(_ a: TaskActivity, origin: TaskOrigin) -> Row {
        // 模块外通过正式关注入口观测纯同步副本标记。禁止回收、没有排除且只有这一个任务。
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var task = CodexTask(id: "fixture", title: "合成任务", project: "synthetic", createdAt: now,
                             updatedAt: now, rolloutURL: URL(fileURLWithPath: "/synthetic.jsonl"), origin: origin)
        task.activity = a
        var prefs = MonitorPreferences()
        prefs.initialized = true
        prefs.autoMonitor = false
        prefs.finishedRetentionDays = 0
        prefs.selectedIDs = [task.id]
        MonitoringPolicy.reconcile(&prefs, tasks: [task], now: now)
        // 不经毫秒 ISO 格式器往返，保留 Date 实际参与次序和间隔运算的精度。
        func seconds(_ date: Date?) -> Any { date.map { $0.timeIntervalSinceReferenceDate as Any } ?? NSNull() }
        let later = Date(timeIntervalSince1970: 1_800_000_920)
        let effective = a.effective(at: later, sourceName: origin.displayName)
        return ["phase": a.phase.rawValue, "label": a.phase.label, "detail": a.detail,
                "lastEventAt": seconds(a.lastEventAt), "startedAt": seconds(a.startedAt),
                "waitingStartedAt": seconds(a.waitingStartedAt), "turnID": a.turnID as Any? ?? NSNull(),
                "waitingElapsedSeconds": a.waitingElapsedSeconds as Any? ?? NSNull(),
                "keepsAutomaticSelection": prefs.selectedIDs.contains(task.id),
                "effectiveAtReferenceSeconds": later.timeIntervalSinceReferenceDate,
                "effectivePhase": effective.phase.rawValue, "effectiveDetail": effective.detail]
    }
}
