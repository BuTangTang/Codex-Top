import Foundation

/// Codex 记录里 `token_count` 事件的累计用量（只读数字，不读内容）。输入里含缓存命中的部分，输出里含推理的部分。
public struct CodexTokens: Equatable, Sendable {
    public var input = 0, cached = 0, output = 0, reasoning = 0
    public init(input: Int = 0, cached: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.input = input; self.cached = cached; self.output = output; self.reasoning = reasoning
    }
    public var total: Int { input + output }
    static func + (a: CodexTokens, b: CodexTokens) -> CodexTokens {
        CodexTokens(input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
    }
    static func - (a: CodexTokens, b: CodexTokens) -> CodexTokens {
        CodexTokens(input: max(0, a.input - b.input), cached: max(0, a.cached - b.cached),
                    output: max(0, a.output - b.output), reasoning: max(0, a.reasoning - b.reasoning))
    }
}

public struct CodexUsageSummary: Equatable, Sendable {
    /// 近 7 天，最早的在前，最后一个是今天。
    public var days: [CodexTokens]
    public var today: CodexTokens { days.last ?? CodexTokens() }
    public var yesterday: CodexTokens { days.count > 1 ? days[days.count - 2] : CodexTokens() }
    public var week: Int { days.reduce(0) { $0 + $1.total } }
    public static let empty = CodexUsageSummary(days: Array(repeating: CodexTokens(), count: 7))
}

/// 统计近 7 天 Codex 的 token 用量。文件列表由调用方从任务列表给出（最近 7 天有更新的普通记录）；
/// 每个文件第一次从头读，之后只读新增部分。同一会话的累计值会重复出现，只按“累计值变大的部分”记到当天。
public actor CodexUsageCounter {
    private struct FileState {
        var offset: UInt64 = 0
        var last = CodexTokens()
        var buckets: [Date: CodexTokens] = [:]
    }
    private var files: [String: FileState] = [:]
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private let whole = ISO8601DateFormatter()

    public init() {}

    public func summary(files urls: [URL], now: Date = .now, calendar: Calendar = .current) -> CodexUsageSummary {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let first = starts.first else { return .empty }
        var days = Array(repeating: CodexTokens(), count: 7)
        var live: Set<String> = []
        for url in urls where url.pathExtension == "jsonl" {
            let path = url.path
            guard live.insert(path).inserted else { continue }
            var state = files[path] ?? FileState()
            read(url, into: &state, calendar: calendar)
            state.buckets = state.buckets.filter { $0.key >= first }
            files[path] = state
            for (index, start) in starts.enumerated() {
                if let tokens = state.buckets[start] { days[index] = days[index] + tokens }
            }
        }
        files = files.filter { live.contains($0.key) }
        return CodexUsageSummary(days: days)
    }

    private func read(_ url: URL, into state: inout FileState, calendar: Calendar) {
        // 不用 URL 的资源缓存：同一个地址对象会一直给出旧的大小。
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size < state.offset { state = FileState() }
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 10) else { return }
        let marker = Data("\"token_count\"".utf8)
        for line in data[data.startIndex..<end].split(separator: 10) where line.range(of: marker) != nil {
            consume(Data(line), into: &state, calendar: calendar)
        }
        state.offset += UInt64(end - data.startIndex + 1)
    }

    private func consume(_ line: Data, into state: inout FileState, calendar: Calendar) {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              value["type"] as? String == "event_msg",
              let payload = value["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any],
              let text = value["timestamp"] as? String, let at = fractional.date(from: text) ?? whole.date(from: text) else { return }
        func number(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let total = CodexTokens(input: number("input_tokens"), cached: number("cached_input_tokens"),
                                output: number("output_tokens"), reasoning: number("reasoning_output_tokens"))
        // 累计值变小说明会话被重新计数（比如压缩上下文后重开），从这里重新起算。
        if total.total < state.last.total { state.last = CodexTokens() }
        let delta = total - state.last
        state.last = total
        guard delta.total > 0 else { return }
        let day = calendar.startOfDay(for: at)
        state.buckets[day] = (state.buckets[day] ?? CodexTokens()) + delta
    }
}
