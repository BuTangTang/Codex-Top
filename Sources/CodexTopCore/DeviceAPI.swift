import Foundation
import CryptoKit

/// REQ-005 设备读取接口：把面板已经算好的结果拼成总览、任务、用量三份内容（格式见设计附录 A）。
/// 这里只做整理，不读任何文件；时间一律秒级时间戳，没有就是 null。
public enum DeviceAPI {
    public static let schemaVersion = 1
    public static let port: UInt16 = 8770
    public static let serviceType = "_codextop._tcp"
    public static let maxTasks = 20
    public static let titleLimit = 40

    // MARK: 总览

    public enum OverallState: String, Codable, Sendable {
        case running, waiting, failed, idle, unknown, loading, paused
        /// 和悬浮球同一套：暂停、读取中、数据源整体读不到先说；否则按关注任务的汇总。
        public init(paused: Bool, loading: Bool, sourceUnavailable: Bool, summary: TaskPhase) {
            if paused { self = .paused }
            else if loading { self = .loading }
            else if sourceUnavailable { self = .unknown }
            else {
                switch summary {
                case .running: self = .running
                case .waiting: self = .waiting
                case .failed: self = .failed
                case .unknown: self = .unknown
                case .idle, .completed, .stopped: self = .idle
                }
            }
        }
    }

    public struct Counts: Codable, Equatable, Sendable {
        public var running: Int, waiting: Int, failed: Int, freshDone: Int, watching: Int, finished: Int
    }

    public struct Status: Codable, Equatable, Sendable {
        public var schemaVersion = DeviceAPI.schemaVersion
        public var generatedAtEpoch: Int
        public var computer: String
        public var state: OverallState
        public var counts: Counts
    }

    public static func status(state: OverallState, summary: MonitorStatusSummary, freshDone: Int, watching: Int, finished: Int,
                              computer: String, now: Date) -> Status {
        Status(generatedAtEpoch: epoch(now), computer: computer, state: state,
               counts: Counts(running: summary.running, waiting: summary.waiting, failed: summary.failed,
                              freshDone: freshDone, watching: watching, finished: finished))
    }

    // MARK: 任务

    public enum Section: String, Codable, Sendable { case attention, fresh, active }

    /// 面板里一行任务的原料。
    public struct TaskInput: Sendable {
        public var id: String
        public var origin: TaskOrigin
        public var title: String
        public var activity: TaskActivity
        public var childCount: Int
        public var section: Section
        public var freshFinishedAt: Date?
        public init(id: String, origin: TaskOrigin, title: String, activity: TaskActivity, childCount: Int, section: Section, freshFinishedAt: Date? = nil) {
            self.id = id; self.origin = origin; self.title = title; self.activity = activity; self.childCount = childCount
            self.section = section; self.freshFinishedAt = freshFinishedAt
        }
    }

    public struct TaskItem: Codable, Equatable, Sendable {
        /// 短编号（设计 v0.3）：打开任务用，倒推不出内部编号。
        public var id: String
        public var source: String
        public var title: String?
        public var phase: String
        public var section: Section
        public var statusText: String
        public var startedAtEpoch: Int?
        public var waitingSinceEpoch: Int?

        enum CodingKeys: String, CodingKey { case id, source, title, phase, section, statusText, startedAtEpoch, waitingSinceEpoch }
        /// 标题关掉时不出现这个字段；两个时间没有就写 null，设备不用猜字段在不在。
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(source, forKey: .source)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(phase, forKey: .phase)
            try container.encode(section, forKey: .section)
            try container.encode(statusText, forKey: .statusText)
            try container.encode(startedAtEpoch, forKey: .startedAtEpoch)
            try container.encode(waitingSinceEpoch, forKey: .waitingSinceEpoch)
        }
    }

    public struct Tasks: Codable, Equatable, Sendable {
        public var schemaVersion = DeviceAPI.schemaVersion
        public var generatedAtEpoch: Int
        public var titles: Bool
        public var items: [TaskItem]
        public var hasMore: Bool
        public var finishedCount: Int
    }

    /// 顺序：需要你处理 → 刚完成 → 进行中（同一段里保持传入的面板顺序）；最多 20 条。
    public static func tasks(_ inputs: [TaskInput], finishedCount: Int, titles: Bool, now: Date) -> Tasks {
        let order: [Section] = [.attention, .fresh, .active]
        let sorted = order.flatMap { section in inputs.filter { $0.section == section } }
        let items = sorted.prefix(maxTasks).map { input in
            TaskItem(id: taskCode(input.id), source: input.origin == .codex ? "codex" : "claude_code",
                     title: titles ? truncated(input.title) : nil,
                     phase: input.activity.phase.rawValue,
                     section: input.section,
                     statusText: TaskStatusText.line(activity: input.activity, childCount: input.childCount, freshFinishedAt: input.freshFinishedAt, now: now),
                     startedAtEpoch: input.activity.startedAt.map(epoch),
                     waitingSinceEpoch: input.activity.phase == .waiting ? input.activity.waitingStartedAt.map(epoch) : nil)
        }
        return Tasks(generatedAtEpoch: epoch(now), titles: titles, items: Array(items), hasMore: sorted.count > maxTasks, finishedCount: finishedCount)
    }

    /// 任务短编号：内部编号加固定前缀做 SHA-256，取前 12 位十六进制。同一任务始终一样，倒推不出会话编号。
    public static func taskCode(_ id: String) -> String {
        SHA256.hash(data: Data("codextop-device:\(id)".utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func truncated(_ title: String) -> String {
        title.count <= titleLimit ? title : String(title.prefix(titleLimit - 1)) + "…"
    }

    // MARK: 用量

    public struct QuotaWindowItem: Codable, Equatable, Sendable {
        public var kind: String
        public var remainingPercent: Int
        public var resetsAtEpoch: Int?
        enum CodingKeys: String, CodingKey { case kind, remainingPercent, resetsAtEpoch }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(remainingPercent, forKey: .remainingPercent)
            try container.encode(resetsAtEpoch, forKey: .resetsAtEpoch)
        }
    }

    public struct Quota: Codable, Equatable, Sendable {
        public var available: Bool
        public var observedAtEpoch: Int?
        public var windows: [QuotaWindowItem]
        enum CodingKeys: String, CodingKey { case available, observedAtEpoch, windows }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(observedAtEpoch, forKey: .observedAtEpoch)
            try container.encode(windows, forKey: .windows)
        }
    }

    public struct Day: Codable, Equatable, Sendable {
        public var startEpoch: Int
        public var total: Int
    }

    /// Codex 今天的构成，各项互不重叠，加起来就是总数（和用量卡片的分段一样）。
    public struct CodexToday: Codable, Equatable, Sendable {
        public var total: Int, input: Int, cached: Int, output: Int, reasoning: Int
    }

    public struct ClaudeToday: Codable, Equatable, Sendable {
        public var total: Int, input: Int, output: Int, cacheRead: Int
    }

    public struct CodexUsage: Codable, Equatable, Sendable {
        public var quota: Quota
        public var today: CodexToday
        public var yesterdayTotal: Int
        public var days: [Day]
    }

    public struct ClaudeUsage: Codable, Equatable, Sendable {
        public var available: Bool
        public var today: ClaudeToday
        public var yesterdayTotal: Int
        public var days: [Day]
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var schemaVersion = DeviceAPI.schemaVersion
        public var generatedAtEpoch: Int
        public var dayStartsAtHour: Int
        public var codex: CodexUsage
        public var claudeCode: ClaudeUsage
    }

    /// 有 5 小时窗口才给 5 小时；周额度给剩余百分比和重置时间；读不到就标出来，保留最后读到的时间。
    public static func usage(quota: QuotaSnapshot?, codex: CodexUsageSummary?, claude: ClaudeUsageSummary?, now: Date,
                             boundary: UsageDayBoundary = .localNoon) -> Usage {
        let fallbackStarts = boundary.starts(endingAt: now)
        func days(_ totals: [Int], _ starts: [Date]) -> [Day] {
            let starts = starts.count == totals.count ? starts : fallbackStarts
            return zip(starts, totals).map { Day(startEpoch: epoch($0), total: $1) }
        }
        let windows = (quota?.windows ?? []).compactMap { window -> QuotaWindowItem? in
            let kind: String
            switch window.minutes {
            case 300: kind = "five_hour"
            case 10080: kind = "week"
            default: return nil
            }
            return QuotaWindowItem(kind: kind, remainingPercent: window.remainingPercent, resetsAtEpoch: window.resetsAt.map(epoch))
        }
        let codexSummary = codex ?? .empty, t = codexSummary.today
        let codexUsage = CodexUsage(
            quota: Quota(available: !windows.isEmpty, observedAtEpoch: quota.map { epoch($0.observedAt) }, windows: windows),
            today: CodexToday(total: t.total, input: max(0, t.input - t.cached), cached: t.cached,
                              output: max(0, t.output - t.reasoning), reasoning: t.reasoning),
            yesterdayTotal: codexSummary.yesterday.total,
            days: days(codexSummary.days.map(\.total), codexSummary.starts))
        let claudeSummary = claude ?? .empty, c = claudeSummary.today
        let claudeUsage = ClaudeUsage(
            available: claude != nil,
            today: ClaudeToday(total: c.total, input: c.input, output: c.output, cacheRead: c.cacheRead),
            yesterdayTotal: claudeSummary.yesterday.total,
            days: days(claudeSummary.days.map(\.total), claudeSummary.starts))
        return Usage(generatedAtEpoch: epoch(now), dayStartsAtHour: boundary.hour, codex: codexUsage, claudeCode: claudeUsage)
    }

    // MARK: 主题和打开任务（设计 v0.3）

    public struct Theme: Codable, Equatable, Sendable {
        public var schemaVersion = DeviceAPI.schemaVersion
        public var generatedAtEpoch: Int
        /// 设置里选的：dark／light／system。
        public var choice: String
        /// 实际显示的：dark／light。
        public var effective: String
    }

    public static func theme(choice: PanelTheme, effectiveIsDark: Bool, now: Date) -> Theme {
        Theme(generatedAtEpoch: epoch(now), choice: choice.rawValue, effective: effectiveIsDark ? "dark" : "light")
    }

    /// 打开任务的结果：打不开时带上和面板一样的提示。
    public struct OpenResult: Codable, Equatable, Sendable {
        public var opened: Bool
        public var message: String?
        public init(opened: Bool, message: String? = nil) { self.opened = opened; self.message = message }
    }

    // MARK: 编码和口令

    /// 键名用下划线写法（`started_at_epoch`），和设计附录 A 一致。
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    /// 6 位数字口令（设计 S2）。
    public static func newToken() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    /// 请求头 `Authorization: Bearer 123456` 里的口令是否和设置里的一致。
    public static func tokenMatches(authorization: String?, token: String?) -> Bool {
        guard let token, !token.isEmpty, let authorization else { return false }
        let parts = authorization.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return parts[1] == token
    }
}
