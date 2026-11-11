import XCTest
import Foundation
@testable import CodexTopCore

/// 底栏 Claude 用量：合成记录、独立临时目录，不读本机真实数据。
final class ClaudeUsageCounterTests: XCTestCase {
    private func line(_ id: String, at: Date, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> String {
        let value: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: at),
                                    "message": ["id": id, "role": "assistant", "content": [["type": "text", "text": "secret"]],
                                                "usage": ["input_tokens": input, "output_tokens": output,
                                                          "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n"
    }

    func testCountsDaysSubagentsAndSkipsDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let main = project.appendingPathComponent("s1.jsonl")
        // 同一条回复写了三行，只算一次；昨天的单独一天；用户行和没有用量的行不算。
        try (line("m1", at: now, input: 100, output: 20, cacheRead: 1_000, cacheWrite: 50)
             + line("m1", at: now, input: 100, output: 20, cacheRead: 1_000, cacheWrite: 50)
             + line("m1", at: now, input: 100, output: 20, cacheRead: 1_000, cacheWrite: 50)
             + line("m0", at: yesterday, input: 10, output: 5)
             + "{\"type\":\"user\",\"timestamp\":\"2027-01-15T08:00:00Z\",\"message\":{\"content\":\"usage\"}}\n").write(to: main, atomically: true, encoding: .utf8)
        try line("a1", at: now, input: 30, output: 10).write(to: project.appendingPathComponent("s1/subagents/agent-1.jsonl"), atomically: true, encoding: .utf8)
        try line("o1", at: now, input: 5, output: 5).write(to: project.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        for url in [main, project.appendingPathComponent("s1/subagents/agent-1.jsonl"), project.appendingPathComponent("s2.jsonl")] {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
        let counter = ClaudeUsageCounter(root: root)
        var summary = await counter.summary(now: now, boundary: UsageDayBoundary(timeZone: calendar.timeZone, hour: 0))
        XCTAssertEqual(summary.today, ClaudeTokens(input: 150 + 30 + 5, output: 20 + 10 + 5, cacheRead: 1_000))
        XCTAssertEqual(summary.yesterday.total, 15)

        // 之后只读新增的部分；重复的编号仍只算一次。
        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd(); try handle.write(contentsOf: Data((line("m1", at: now, input: 100, output: 20) + line("m2", at: now, input: 1, output: 1)).utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: main.path)
        summary = await counter.summary(now: now, boundary: UsageDayBoundary(timeZone: calendar.timeZone, hour: 0))
        XCTAssertEqual(summary.today.total, 185 + 35 + 1_000 + 2)
        XCTAssertEqual(summary.week, summary.today.total + 15)
    }

    /// 续接的会话把旧记录复制进新文件：同一编号跨文件也只算一次，新文件里新增的照算。
    func testCopiedRecordsInResumedSessionCountOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = project.appendingPathComponent("s1.jsonl"), resumed = project.appendingPathComponent("s2.jsonl")
        try (line("m1", at: now, input: 100, output: 10) + line("m2", at: now, input: 200, output: 20)).write(to: old, atomically: true, encoding: .utf8)
        try (line("m1", at: now, input: 100, output: 10) + line("m2", at: now, input: 200, output: 20)
             + line("m3", at: now, input: 5, output: 1)).write(to: resumed, atomically: true, encoding: .utf8)
        for url in [old, resumed] { try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path) }
        let summary = await ClaudeUsageCounter(root: root).summary(now: now, boundary: UsageDayBoundary(timeZone: calendar.timeZone, hour: 0))
        XCTAssertEqual(summary.today, ClaudeTokens(input: 305, output: 31))
    }

    /// 中午 12 点切天：中午以后到第二天上午算同一天，上午还没到中午算前一天。
    func testDayStartsAtNoon() async throws {
        let f = ISO8601DateFormatter(), boundary = UsageDayBoundary(timeZone: TimeZone(identifier: "UTC")!, hour: 12)
        let noon = f.date(from: "2027-01-15T12:00:00Z")!
        XCTAssertEqual(boundary.start(of: f.date(from: "2027-01-15T12:01:00Z")!), noon)
        XCTAssertEqual(boundary.start(of: f.date(from: "2027-01-16T01:30:00Z")!), noon)
        XCTAssertEqual(boundary.start(of: f.date(from: "2027-01-15T11:59:00Z")!), f.date(from: "2027-01-14T12:00:00Z")!)
        XCTAssertEqual(boundary.starts(endingAt: f.date(from: "2027-01-16T01:30:00Z")!), (0..<7).reversed().map { noon.addingTimeInterval(-86_400 * Double($0)) })

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let now = f.date(from: "2027-01-16T01:30:00Z")!, file = project.appendingPathComponent("s.jsonl")
        try (line("a", at: f.date(from: "2027-01-15T11:00:00Z")!, input: 1, output: 0)
             + line("b", at: f.date(from: "2027-01-15T13:00:00Z")!, input: 10, output: 0)
             + line("c", at: f.date(from: "2027-01-16T01:00:00Z")!, input: 100, output: 0)).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let summary = await ClaudeUsageCounter(root: root).summary(now: now, boundary: boundary)
        XCTAssertEqual(summary.today.total, 110)
        XCTAssertEqual(summary.yesterday.total, 1)
        XCTAssertEqual(summary.starts.last, noon)
    }
}
