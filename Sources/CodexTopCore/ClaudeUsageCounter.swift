import Foundation

/// 本机 Claude Code 记录里每次回复写下的 token 数（只读数字，不读内容）。
public struct ClaudeTokens: Equatable, Sendable {
    /// 输入含写入缓存的部分；缓存读取单独算。
    public var input = 0, output = 0, cacheRead = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0) { self.input = input; self.output = output; self.cacheRead = cacheRead }
    public var total: Int { input + output + cacheRead }
    static func + (a: ClaudeTokens, b: ClaudeTokens) -> ClaudeTokens {
        ClaudeTokens(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead)
    }
}

/// 用量按天分桶的切点。Claude 和 Codex 都按电脑本地时间中午 12 点切天（2026-11-11 用户定：夜里干活不该在零点被切开）。
public struct UsageDayBoundary: Sendable {
    public var timeZone: TimeZone
    public var hour: Int
    public init(timeZone: TimeZone, hour: Int) { self.timeZone = timeZone; self.hour = hour }
    public static var localNoon: UsageDayBoundary { UsageDayBoundary(timeZone: .current, hour: 12) }
    private var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; return calendar }
    /// 包含这个时刻的那一天从什么时候开始。
    public func start(of date: Date) -> Date {
        let calendar = calendar
        let mark = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        return mark <= date ? mark : calendar.date(byAdding: .day, value: -1, to: mark) ?? mark
    }
    /// 最近几天的起点，最早的在前，最后一个是今天。
    public func starts(endingAt now: Date, count: Int = 7) -> [Date] {
        let today = start(of: now), calendar = calendar
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
}

public struct ClaudeUsageSummary: Equatable, Sendable {
    /// 近 7 天，最早的在前，最后一个是今天。
    public var days: [ClaudeTokens]
    /// 每一天从什么时候开始，和 days 一一对应；界面按它标星期。
    public var starts: [Date] = []
    public var today: ClaudeTokens { days.last ?? ClaudeTokens() }
    public var yesterday: ClaudeTokens { days.count > 1 ? days[days.count - 2] : ClaudeTokens() }
    public var week: Int { days.reduce(0) { $0 + $1.total } }
    public static let empty = ClaudeUsageSummary(days: Array(repeating: ClaudeTokens(), count: 7))
}

/// 统计近 7 天 Claude Code 的 token 用量：只读最近 7 天改过的记录，之后每次只读新增的部分。
/// 同一条回复会被写成好几行（同一个消息编号），按编号只算一次；
/// 续接的会话会把旧记录复制进新文件，所以去重跨文件做（2026-11-11 核对本机记录：845 条回复在两个文件里各算了一次）。
public actor ClaudeUsageCounter {
    private struct Entry { var day: Date; var tokens: ClaudeTokens }
    private struct FileState {
        var offset: UInt64 = 0
        var entries: [String: Entry] = [:]
        /// 没有消息编号的行，没法去重，按天直接累加。
        var unnamed: [Date: ClaudeTokens] = [:]
    }
    private let root: URL
    private var files: [String: FileState] = [:]
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private let whole = ISO8601DateFormatter()

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func summary(now: Date = .now, boundary: UsageDayBoundary = .localNoon) -> ClaudeUsageSummary {
        let starts = boundary.starts(endingAt: now)
        guard let first = starts.first else { return .empty }
        var buckets: [Date: ClaudeTokens] = [:]
        var counted: [String: Date] = [:]
        var live: Set<String> = []
        for url in transcripts(modifiedSince: first) {
            let path = url.path
            live.insert(path)
            var state = files[path] ?? FileState()
            read(url, into: &state, boundary: boundary)
            state.entries = state.entries.filter { $0.value.day >= first }
            state.unnamed = state.unnamed.filter { $0.key >= first }
            files[path] = state
        }
        files = files.filter { live.contains($0.key) }
        // 文件按路径排序再合并，同一编号只记第一次出现的那份；副本的时间和原记录一样。
        for path in files.keys.sorted() {
            guard let state = files[path] else { continue }
            for (id, entry) in state.entries where counted[id] == nil {
                counted[id] = entry.day
                buckets[entry.day] = (buckets[entry.day] ?? ClaudeTokens()) + entry.tokens
            }
            for (day, tokens) in state.unnamed { buckets[day] = (buckets[day] ?? ClaudeTokens()) + tokens }
        }
        return ClaudeUsageSummary(days: starts.map { buckets[$0] ?? ClaudeTokens() }, starts: starts)
    }

    /// `projects/<项目>/<会话>.jsonl` 和子代理的 `projects/<项目>/<会话>/subagents/*.jsonl`。
    private func transcripts(modifiedSince start: Date) -> [URL] {
        let fm = FileManager.default, keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        func recent(_ url: URL) -> Bool {
            guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let modified = values.contentModificationDate else { return false }
            return modified >= start
        }
        var result: [URL] = []
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for entry in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? [] {
                if recent(entry) { result.append(entry); continue }
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                for file in (try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: keys)) ?? [] where recent(file) {
                    result.append(file)
                }
            }
        }
        return result
    }

    /// 从上次读到的位置读到最后一个换行；文件变短（被重写）就从头读。
    private func read(_ url: URL, into state: inout FileState, boundary: UsageDayBoundary) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
        if size < state.offset { state = FileState() }
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 10) else { return }
        let marker = Data("\"usage\"".utf8)
        for line in data[data.startIndex..<end].split(separator: 10) where line.range(of: marker) != nil {
            consume(Data(line), into: &state, boundary: boundary)
        }
        state.offset += UInt64(end - data.startIndex + 1)
    }

    private func consume(_ line: Data, into state: inout FileState, boundary: UsageDayBoundary) {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              value["type"] as? String == "assistant", value["isApiErrorMessage"] as? Bool != true,
              let message = value["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
              let text = value["timestamp"] as? String, let at = fractional.date(from: text) ?? whole.date(from: text) else { return }
        func number(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let tokens = ClaudeTokens(input: number("input_tokens") + number("cache_creation_input_tokens"),
                                  output: number("output_tokens"), cacheRead: number("cache_read_input_tokens"))
        let day = boundary.start(of: at)
        if let id = message["id"] as? String {
            if state.entries[id] == nil { state.entries[id] = Entry(day: day, tokens: tokens) }
        } else {
            state.unnamed[day] = (state.unnamed[day] ?? ClaudeTokens()) + tokens
        }
    }
}
