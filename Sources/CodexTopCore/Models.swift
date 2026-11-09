import Foundation

public enum TaskPhase: String, Codable, Sendable, CaseIterable {
    case running, waiting, completed, failed, stopped, idle, unknown
    public var label: String {
        switch self {
        case .running: "运行中"
        case .waiting: "待处理"
        case .completed: "已完成"
        case .failed: "出错"
        case .stopped: "已停止"
        case .idle: "未运行"
        case .unknown: "状态未知"
        }
    }
    public var priority: Int {
        switch self {
        case .waiting: 0
        case .failed: 1
        case .running: 2
        case .unknown: 3
        case .idle: 4
        case .stopped: 5
        case .completed: 6
        }
    }
    public var isActive: Bool { self == .running || self == .waiting }
    public var isFinished: Bool { self == .completed || self == .stopped }
}

public struct TaskActivity: Equatable, Sendable {
    public var phase: TaskPhase = .unknown
    public var detail: String = "尚无可识别的活动记录"
    public var lastEventAt: Date?
    public var startedAt: Date?
    public var waitingStartedAt: Date?
    public var turnID: String?
    public init(phase: TaskPhase = .unknown, detail: String = "尚无可识别的活动记录", lastEventAt: Date? = nil, startedAt: Date? = nil, waitingStartedAt: Date? = nil) {
        self.phase = phase; self.detail = detail; self.lastEventAt = lastEventAt; self.startedAt = startedAt
        self.waitingStartedAt = waitingStartedAt
    }
    /// Elapsed wall time from this turn's start to entering the current wait, not CPU time or a live timer.
    public var waitingElapsedSeconds: Int? {
        guard phase == .waiting, let startedAt, let waitingStartedAt,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              waitingStartedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let elapsed = waitingStartedAt.timeIntervalSince(startedAt)
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else { return nil }
        return Int(elapsed)
    }
    public func effective(at now: Date, staleAfter: TimeInterval = 900, sourceName: String = "Codex") -> TaskActivity {
        var copy = self
        if phase == .running, let lastEventAt, now.timeIntervalSince(lastEventAt) > staleAfter {
            copy.phase = .unknown
            copy.detail = "较久未收到新活动，请回到 \(sourceName) 查看"
        }
        return copy
    }
}

/// 任务来自哪个工具；Claude Code 任务编号以 `cc:` 开头（REQ-003 设计 2.3）。
public enum TaskOrigin: String, Sendable, Equatable {
    case codex, claudeCode
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
    public var mark: String { self == .codex ? "CX" : "CC" }
}

/// Claude Code 会话从哪里打开；来自运行登记，进程退出后为空。
public struct ClaudeLaunch: Equatable, Sendable {
    public var fromDesktopApp: Bool
    /// 桌面 App 里的会话编号（`local_…`）。
    public var hostSessionID: String?
    public init(fromDesktopApp: Bool, hostSessionID: String?) { self.fromDesktopApp = fromDesktopApp; self.hostSessionID = hostSessionID }
}

public struct CodexTask: Identifiable, Sendable, Equatable {
    public let id: String
    public var origin: TaskOrigin
    public var claudeLaunch: ClaudeLaunch?
    public var title: String
    public var project: String
    public var createdAt: Date
    public var updatedAt: Date
    public var parentID: String?
    public var rolloutURL: URL
    public var activity = TaskActivity()
    public init(id: String, title: String, project: String, createdAt: Date, updatedAt: Date, parentID: String? = nil, rolloutURL: URL,
                origin: TaskOrigin = .codex) {
        self.id = id; self.origin = origin; self.title = title; self.project = project
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.parentID = parentID; self.rolloutURL = rolloutURL
    }
    public var deepLink: URL? {
        switch origin {
        case .codex:
            guard UUID(uuidString: id) != nil else { return nil }
            return URL(string: "codex://threads/\(id)")
        case .claudeCode:
            // 只有桌面 App 的会话能直达；编号来自运行登记，格式不对就不拼链接。
            guard let launch = claudeLaunch, launch.fromDesktopApp, let host = launch.hostSessionID,
                  host.hasPrefix("local_"), UUID(uuidString: String(host.dropFirst(6))) != nil else { return nil }
            return URL(string: "claude://claude.ai/epitaxy/\(host)")
        }
    }
    /// Claude Code 会话编号（不含 `cc:` 前缀），复制给用户用。
    public var claudeSessionID: String? { origin == .claudeCode ? String(id.dropFirst(3)) : nil }
}

public struct QuotaWindow: Equatable, Sendable {
    public let minutes: Int
    public let usedPercent: Double
    public let resetsAt: Date?
    public init(minutes: Int, usedPercent: Double, resetsAt: Date? = nil) {
        self.minutes = minutes; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
    public var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent)).rounded()) }
}
public enum QuotaOrigin: String, Sendable { case log, account }
public struct QuotaSnapshot: Equatable, Sendable {
    public let observedAt: Date
    public let windows: [QuotaWindow]
    public let origin: QuotaOrigin
    public init(observedAt: Date, windows: [QuotaWindow], origin: QuotaOrigin = .log) {
        self.observedAt = observedAt; self.windows = windows; self.origin = origin
    }
    public var fiveHour: QuotaWindow? { windows.first { $0.minutes == 300 } }
    public var weekly: QuotaWindow? { windows.first { $0.minutes == 10080 } }
}

public struct SourceSnapshot: Sendable {
    public var tasks: [CodexTask]
    public var quota: QuotaSnapshot?
    public var warning: String?
    public var bytesRead: Int
    public var observedAt: Date
    public init(tasks: [CodexTask], quota: QuotaSnapshot? = nil, warning: String? = nil, bytesRead: Int = 0, observedAt: Date = .now) {
        self.tasks = tasks; self.quota = quota; self.warning = warning; self.bytesRead = bytesRead; self.observedAt = observedAt
    }
}

public enum CodexSourceError: LocalizedError {
    case missingDatabase, incompatibleDatabase, databaseUnavailable, unreadableLog
    public var errorDescription: String? {
        switch self {
        case .missingDatabase: "未找到 Codex 任务数据库。请先在 Codex 创建任务，或选择正确的数据目录。"
        case .incompatibleDatabase: "当前 Codex 数据格式不受支持，请更新 Codex Top。"
        case .databaseUnavailable: "暂时无法读取 Codex 数据库，请稍后刷新或检查目录权限。"
        case .unreadableLog: "部分任务记录无法读取。"
        }
    }
}
