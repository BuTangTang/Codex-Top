import Foundation

/// REQ-003 层 C：hooks 小程序写下的事件，只有会话编号（文件名）、通知类型和时间（R-14）。
public struct ClaudeHookEvent: Equatable, Sendable {
    public let kind: String
    public let at: Date
    public init(kind: String, at: Date) { self.kind = kind; self.at = at }
}

public enum ClaudeHookEvents {
    /// 只认这两种通知：需要你批准、需要你填写（MCP 对话框）。其余类型一律不记。
    public static let kinds: Set<String> = ["permission_prompt", "elicitation_dialog"]
    static let maximumFileBytes = 256 * 1024

    /// 小程序用：从 cc 传来的 JSON 里只取会话编号、事件名和通知类型，加当前时间追加一行；
    /// 消息正文、工作目录、记录路径等其余字段全部丢弃。任何问题都静默放弃，不影响 cc。
    public static func record(input: Data, directory: URL, now: Date = .now) {
        guard let value = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              value["hook_event_name"] as? String == "Notification",
              let kind = value["notification_type"] as? String, kinds.contains(kind),
              let session = value["session_id"] as? String, isSafeSessionID(session) else { return }
        let line = "{\"t\":\"\(kind)\",\"at\":\"\(timestamp(now))\"}\n"
        let url = directory.appendingPathComponent(session + ".jsonl")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(Data(line.utf8))
        // 单个文件超过 256 KiB 只留后半段（从一个整行开始）。
        if data.count > maximumFileBytes, let cut = data[(data.count / 2)...].firstIndex(of: 10) {
            data = Data(data[(cut + 1)...])
        }
        try? data.write(to: url, options: .atomic)
    }

    /// 读某个会话最近的一条事件；没有文件或读不出来时为 nil（退回只看记录和登记）。
    public static func latest(directory: URL, session: String) -> ClaudeHookEvent? {
        guard isSafeSessionID(session), let data = try? Data(contentsOf: directory.appendingPathComponent(session + ".jsonl")) else { return nil }
        for line in data.split(separator: 10).reversed() {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let kind = value["t"] as? String, kinds.contains(kind),
                  let text = value["at"] as? String, let at = date(text) else { continue }
            return ClaudeHookEvent(kind: kind, at: at)
        }
        return nil
    }

    /// 叠加规则（设计 4.2）：记录显示还在运行，而“需要你批准／填写”的事件比记录里最近的活动更新，就是在等你；
    /// 记录里一出现更新的行（你批准了、工具开始有结果），自然回到记录得出的状态。
    public static func apply(_ event: ClaudeHookEvent?, to activity: TaskActivity) -> TaskActivity {
        guard let event, activity.phase == .running, event.at > (activity.lastEventAt ?? .distantPast) else { return activity }
        var waiting = activity
        waiting.phase = .waiting
        waiting.detail = event.kind == "permission_prompt" ? "等待你批准" : "等待你填写"
        waiting.waitingStartedAt = event.at
        waiting.lastEventAt = event.at
        return waiting
    }

    /// 会话编号要能直接当文件名：只允许字母、数字、横线和下划线。
    static func isSafeSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
