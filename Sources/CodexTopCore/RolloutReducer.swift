import Foundation

/// Consumes only event metadata. Message bodies and tool arguments are never retained.
public struct RolloutReducer: Sendable {
    public private(set) var activity = TaskActivity()
    public private(set) var quota: QuotaSnapshot?
    private var waitingCallIDs: Set<String> = []
    private var asynchronousQuestion = false
    public init() {}

    public mutating func consume(_ line: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = value["payload"] as? [String: Any],
              let kind = value["type"] as? String else { return }
        let at = Self.date(value["timestamp"])
        // Old records may arrive after newer records during a compaction/replay.
        if let at, let last = activity.lastEventAt, at < last { return }
        let type = payload["type"] as? String ?? ""
        if kind == "event_msg", ["task_complete", "turn_complete", "turn_aborted", "task_cancelled", "turn_cancelled", "task_failed", "turn_failed"].contains(type),
           let turn = payload["turn_id"] as? String, let current = activity.turnID, turn != current { return }
        let userItem = type == "item_completed" && ((payload["item"] as? [String: Any])?["type"] as? String)?.lowercased() == "usermessage"
        let explicitContinuation = kind == "event_msg" && (["task_started", "turn_started", "user_message", "user_input", "approval_resolved"].contains(type) || userItem)
        // A trailing explanation or tool result does not prove a failed turn resumed.
        if activity.phase == .failed && !explicitContinuation {
            if kind == "event_msg", type == "token_count", let limits = payload["rate_limits"] as? [String: Any], let at {
                updateQuota(limits, at: at); activity.lastEventAt = at
            }
            return
        }
        if kind == "event_msg" {
            switch type {
            case "task_started", "turn_started":
                activity = TaskActivity(phase: .running, detail: "正在执行", lastEventAt: at, startedAt: at)
                activity.turnID = payload["turn_id"] as? String
                waitingCallIDs.removeAll()
                asynchronousQuestion = false
            case "task_complete", "turn_complete":
                activity.phase = asynchronousQuestion ? .waiting : .completed
                activity.detail = asynchronousQuestion ? "等待你的回答" : "本轮执行已结束"
                waitingCallIDs.removeAll()
            case "turn_aborted", "task_cancelled", "turn_cancelled":
                activity.phase = .stopped; activity.detail = "本轮执行已停止"; waitingCallIDs.removeAll()
            case "task_failed", "turn_failed":
                activity.phase = .failed; activity.detail = "执行遇到问题，请回到 Codex 查看"; waitingCallIDs.removeAll()
            case "request_user_input", "user_input_requested", "exec_approval_request", "apply_patch_approval_request":
                activity.phase = .waiting; activity.detail = "等待你的输入或确认"
            case "user_message", "user_input", "approval_resolved":
                active(at, detail: "收到输入，正在继续"); waitingCallIDs.removeAll(); asynchronousQuestion = false
            case "agent_message", "agent_reasoning":
                if activity.phase != .waiting && !activity.phase.isFinished { active(at, detail: "正在处理任务") }
            case "token_count":
                if let limits = payload["rate_limits"] as? [String: Any], let at { updateQuota(limits, at: at) }
            case "item_completed":
                if let item = payload["item"] as? [String: Any] {
                    let itemType = (item["type"] as? String ?? "").lowercased()
                    if itemType == "usermessage" { active(at, detail: "收到输入，正在继续"); waitingCallIDs.removeAll(); asynchronousQuestion = false }
                    else if ["commandexecution", "filechange", "reasoning", "mcptoolcall"].contains(itemType), activity.phase != .waiting, !activity.phase.isFinished {
                        active(at, detail: itemType == "filechange" ? "正在修改文件" : "正在执行任务")
                    }
                }
            default: return
            }
            if let at { activity.lastEventAt = at }
        } else if kind == "response_item" {
            if type == "function_call" || type == "custom_tool_call" {
                let name = payload["name"] as? String ?? ""
                if name == "request_user_input" || name == "request_user_input_async" || name.hasSuffix("__request_user_input") {
                    activity.phase = .waiting; activity.detail = "等待你的回答"
                    if name == "request_user_input_async" { asynchronousQuestion = true }
                    else if let id = payload["call_id"] as? String { waitingCallIDs.insert(id) }
                } else if activity.phase != .waiting { active(at, detail: "正在执行任务") }
                if let at { activity.lastEventAt = at }
            } else if type == "function_call_output" || type == "custom_tool_call_output" {
                if let id = payload["call_id"] as? String, waitingCallIDs.remove(id) != nil, waitingCallIDs.isEmpty {
                    active(at, detail: "已收到回答，正在继续")
                }
                if let at { activity.lastEventAt = at }
            }
        }
    }
    private mutating func active(_ at: Date?, detail: String) {
        if activity.phase.isFinished || activity.phase == .failed { activity.startedAt = at; activity.turnID = nil }
        activity.phase = .running; activity.detail = detail
    }
    private mutating func updateQuota(_ limits: [String: Any], at: Date) {
        if let id = limits["limit_id"] as? String, id != "codex" { return }
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double, used.isFinite else { continue }
            let minutes = (w["window_minutes"] as? Int) ?? ((w["limit_window_seconds"] as? Int).map { $0 / 60 })
            guard let minutes, minutes > 0 else { continue }
            windows.append(QuotaWindow(minutes: minutes, usedPercent: used, resetsAt: (w["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))))
        }
        if !windows.isEmpty { quota = QuotaSnapshot(observedAt: at, windows: windows) }
    }
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

public struct IncrementalRollout: Sendable {
    public private(set) var reducer = RolloutReducer()
    public private(set) var offset: UInt64 = 0
    private var inode: UInt64?
    private var modified: Date?
    private var pending = Data()
    private var skippingLongLine = false
    private let maximumRead: Int
    public init(maximumRead: Int = 65_536) { self.maximumRead = max(1024, maximumRead) }
    /// Returns bytes actually read; unchanged files incur only a metadata check.
    public mutating func refresh(url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let newInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let newModified = attributes[.modificationDate] as? Date
        if inode == newInode && size == offset && modified == newModified { return 0 }
        let reset = inode != newInode || size < offset || (size == offset && modified != newModified)
        if reset { reducer = RolloutReducer(); offset = 0; pending.removeAll(); skippingLongLine = false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // Cap cold starts and catch-up after very large output bursts.
        let start = max(offset, size > UInt64(maximumRead) ? size - UInt64(maximumRead) : 0)
        let skipped = start > offset
        if skipped { pending.removeAll(); skippingLongLine = true; reducer = RolloutReducer() }
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: maximumRead) ?? Data()
        offset = start + UInt64(data.count); inode = newInode; modified = newModified
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            if !skippingLongLine && !line.isEmpty { reducer.consume(Data(line)) }
            skippingLongLine = false
            pending.removeSubrange(...newline)
        }
        if pending.count > maximumRead { pending.removeAll(); skippingLongLine = true }
        return data.count
    }
}
