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
    public var turnID: String?
    public init(phase: TaskPhase = .unknown, detail: String = "尚无可识别的活动记录", lastEventAt: Date? = nil, startedAt: Date? = nil) {
        self.phase = phase; self.detail = detail; self.lastEventAt = lastEventAt; self.startedAt = startedAt
    }
    public func effective(at now: Date, staleAfter: TimeInterval = 900) -> TaskActivity {
        var copy = self
        if phase == .running, let lastEventAt, now.timeIntervalSince(lastEventAt) > staleAfter {
            copy.phase = .unknown
            copy.detail = "较久未收到新活动，请回到 Codex 查看"
        }
        return copy
    }
}

public struct CodexTask: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var project: String
    public var createdAt: Date
    public var updatedAt: Date
    public var parentID: String?
    public var rolloutURL: URL
    public var activity = TaskActivity()
    public init(id: String, title: String, project: String, createdAt: Date, updatedAt: Date, parentID: String? = nil, rolloutURL: URL) {
        self.id = id; self.title = title; self.project = project
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.parentID = parentID; self.rolloutURL = rolloutURL
    }
    public var deepLink: URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
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
