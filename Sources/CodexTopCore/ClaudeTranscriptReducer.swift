import Foundation

/// REQ-003 层 A：逐行消费 Claude Code 会话记录，只看类型、时间、结束原因、工具名与调用编号，
/// 不保留消息正文和工具参数（R-23）。子代理行与元信息行不参与主会话状态。
public struct ClaudeTranscriptReducer: Sendable {
    public private(set) var activity = TaskActivity()
    private var customTitle: String?
    private var agentName: String?
    /// 标题依次取自定义标题、会话名（设计 3.2）。
    public var title: String? { customTitle ?? agentName }
    public private(set) var workingDirectory: String?
    public private(set) var firstEventAt: Date?
    /// 主会话里尚未返回结果的工具调用；提问与退出计划另记，结果返回即解除等待。
    private var openToolCalls: Set<String> = []
    private var waitingCalls: Set<String> = []
    /// 桌面 App 的收尾提问：本轮调用 `mcp__ccd_turn__wrap_up` 且带非空 `ask`，结束后等你确认（D-87）。
    /// 只记有没有提问，不保留提问文字（R-23）。
    private var endsWithQuestion = false

    public init() {}

    public mutating func consume(_ line: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = value["type"] as? String else { return }
        switch kind {
        case "custom-title":
            if let text = (value["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { customTitle = text }
            return
        case "agent-name":
            // 自定义标题优先；会话名只在没有自定义标题时使用。
            if let text = (value["agentName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { agentName = text }
            return
        case "user", "assistant":
            break
        default:
            return
        }
        if value["isSidechain"] as? Bool == true { return }
        let at = Self.date(value["timestamp"])
        if let at, let last = activity.lastEventAt, at < last { return }
        if let at, firstEventAt == nil { firstEventAt = at }
        if let cwd = value["cwd"] as? String, !cwd.isEmpty { workingDirectory = cwd }
        let message = value["message"] as? [String: Any]
        let content = message?["content"]
        if kind == "user" {
            consumeUser(value, content: content, at: at)
        } else {
            consumeAssistant(value, message: message, content: content, at: at)
        }
    }

    private mutating func consumeUser(_ value: [String: Any], content: Any?, at: Date?) {
        let text = Self.firstText(content)
        if let text, text.hasPrefix("[Request interrupted by user") {
            finish(.stopped, detail: "本轮执行已停止", at: at); return
        }
        let results = Self.items(content).filter { $0["type"] as? String == "tool_result" }
        if !results.isEmpty {
            for result in results {
                if let id = result["tool_use_id"] as? String { openToolCalls.remove(id); waitingCalls.remove(id) }
            }
            guard !activity.phase.isFinished, activity.phase != .failed else { return }
            if waitingCalls.isEmpty { running(at, detail: "收到输入，正在继续") } else { activity.lastEventAt = at ?? activity.lastEventAt }
            return
        }
        if value["isMeta"] as? Bool == true {
            // Stop hook 反馈会让 Claude 继续这一轮，其余元信息行不改变状态。
            if let text, text.hasPrefix("Stop hook feedback:"), activity.phase == .completed { running(at, detail: "正在继续") }
            return
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        activity = TaskActivity(phase: .running, detail: "正在执行", lastEventAt: at, startedAt: at)
        openToolCalls.removeAll(); waitingCalls.removeAll(); endsWithQuestion = false
    }

    private mutating func consumeAssistant(_ value: [String: Any], message: [String: Any]?, content: Any?, at: Date?) {
        if value["isApiErrorMessage"] as? Bool == true {
            finish(.failed, detail: "执行遇到问题，请回到 Claude Code 查看", at: at); return
        }
        var question: String?, tool: String?
        // 副标题只看工具名和有没有思考块，不读参数和正文（R-23）。
        let thinking = Self.items(content).contains { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
        for item in Self.items(content) where item["type"] as? String == "tool_use" {
            guard let id = item["id"] as? String else { continue }
            openToolCalls.insert(id)
            switch item["name"] as? String {
            case "AskUserQuestion": waitingCalls.insert(id); question = "等待你的回答"
            case "ExitPlanMode": waitingCalls.insert(id); question = question ?? "等待你的确认"
            case "mcp__ccd_turn__wrap_up":
                // 以最后一次收尾为准：先带提问、被退回后再不带提问地收尾，就不算在等你（2026-11-09）。
                let ask = (item["input"] as? [String: Any])?["ask"] as? String
                endsWithQuestion = !(ask ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let name?: tool = name
            default: break
            }
        }
        if let question {
            activity.phase = .waiting; activity.detail = question; activity.lastEventAt = at ?? activity.lastEventAt
            if activity.waitingStartedAt == nil { activity.waitingStartedAt = at }
            return
        }
        let stopReason = message?["stop_reason"] as? String
        if stopReason == "end_turn", !(message?["model"] as? String == "<synthetic>" && Self.firstText(content) == "No response requested.") {
            guard waitingCalls.isEmpty else { return }
            if endsWithQuestion {
                activity.phase = .waiting; activity.detail = "等待你确认"; activity.lastEventAt = at ?? activity.lastEventAt
                if activity.waitingStartedAt == nil { activity.waitingStartedAt = at }
            } else {
                finish(.completed, detail: "本轮执行已结束", at: at)
            }
            return
        }
        if waitingCalls.isEmpty, !activity.phase.isFinished, activity.phase != .failed {
            running(at, detail: tool.map(ToolActivityText.detail(forTool:)) ?? (thinking ? "正在思考" : "正在处理任务"))
        }
    }

    private mutating func running(_ at: Date?, detail: String) {
        activity.phase = .running; activity.detail = detail; activity.waitingStartedAt = nil
        activity.lastEventAt = at ?? activity.lastEventAt
    }

    private mutating func finish(_ phase: TaskPhase, detail: String, at: Date?) {
        activity.phase = phase; activity.detail = detail; activity.waitingStartedAt = nil
        activity.lastEventAt = at ?? activity.lastEventAt
        openToolCalls.removeAll(); waitingCalls.removeAll(); endsWithQuestion = false
    }

    private static func items(_ content: Any?) -> [[String: Any]] { content as? [[String: Any]] ?? [] }

    private static func firstText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        return items(content).first { $0["text"] is String }?["text"] as? String
    }

    /// 复用系统的 ISO 8601 解析样式，避免每条记录创建格式器；缺失或无效时间保持为空。
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        // 先接受含小数秒的记录，再兼容整秒；时区偏移仍由记录自身决定。
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
