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

public struct ClaudeUsageSummary: Equatable, Sendable {
    /// 近 7 天，最早的在前，最后一个是今天。
    public var days: [ClaudeTokens]
    public var today: ClaudeTokens { days.last ?? ClaudeTokens() }
    public var yesterday: ClaudeTokens { days.count > 1 ? days[days.count - 2] : ClaudeTokens() }
    public var week: Int { days.reduce(0) { $0 + $1.total } }
    public static let empty = ClaudeUsageSummary(days: Array(repeating: ClaudeTokens(), count: 7))
}

/// 统计近 7 天 Claude Code 的 token 用量：只读最近 7 天改过的记录，之后每次只读新增的部分。
/// 同一条回复会被写成好几行（同一个消息编号），按编号只算一次。
public actor ClaudeUsageCounter {
    private struct FileState {
        var offset: UInt64 = 0
        var buckets: [Date: ClaudeTokens] = [:]
        var seen: Set<String> = []
    }
    private let root: URL
    private var files: [String: FileState] = [:]
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private let whole = ISO8601DateFormatter()

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func summary(now: Date = .now, calendar: Calendar = .current) -> ClaudeUsageSummary {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let first = starts.first else { return .empty }
        var days = Array(repeating: ClaudeTokens(), count: 7)
        var live: Set<String> = []
        for url in transcripts(modifiedSince: first) {
            let path = url.path
            live.insert(path)
            var state = files[path] ?? FileState()
            read(url, into: &state, calendar: calendar)
            state.buckets = state.buckets.filter { $0.key >= first }
            files[path] = state
            for (index, start) in starts.enumerated() {
                if let tokens = state.buckets[start] { days[index] = days[index] + tokens }
            }
        }
        files = files.filter { live.contains($0.key) }
        return ClaudeUsageSummary(days: days)
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
    private func read(_ url: URL, into state: inout FileState, calendar: Calendar) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
        if size < state.offset { state = FileState() }
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 10) else { return }
        let marker = Data("\"usage\"".utf8)
        for line in data[data.startIndex..<end].split(separator: 10) where line.range(of: marker) != nil {
            consume(Data(line), into: &state, calendar: calendar)
        }
        state.offset += UInt64(end - data.startIndex + 1)
    }

    private func consume(_ line: Data, into state: inout FileState, calendar: Calendar) {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              value["type"] as? String == "assistant", value["isApiErrorMessage"] as? Bool != true,
              let message = value["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
              let text = value["timestamp"] as? String, let at = fractional.date(from: text) ?? whole.date(from: text) else { return }
        if let id = message["id"] as? String {
            guard state.seen.insert(id).inserted else { return }
        }
        func number(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let tokens = ClaudeTokens(input: number("input_tokens") + number("cache_creation_input_tokens"),
                                  output: number("output_tokens"), cacheRead: number("cache_read_input_tokens"))
        let day = calendar.startOfDay(for: at)
        state.buckets[day] = (state.buckets[day] ?? ClaudeTokens()) + tokens
    }
}
