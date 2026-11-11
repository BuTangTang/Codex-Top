import XCTest
import Foundation
@testable import CodexTopCore

/// 底栏 Codex 用量：合成 token_count 事件、独立临时目录。
final class CodexUsageCounterTests: XCTestCase {
    private func event(at: Date, input: Int, cached: Int, output: Int, reasoning: Int) -> String {
        let total: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                    "reasoning_output_tokens": reasoning, "total_tokens": input + output]
        let value: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: at), "type": "event_msg",
                                    "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": total]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n"
    }

    func testCountsGrowthOfCumulativeTotalsPerDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000), yesterday = now.addingTimeInterval(-86_400)
        let file = directory.appendingPathComponent("rollout-a.jsonl")
        // 昨天累计到 100；今天累计到 160，同一个累计值重复出现只算一次。
        try (event(at: yesterday, input: 80, cached: 30, output: 20, reasoning: 5)
             + event(at: now, input: 120, cached: 50, output: 40, reasoning: 10)
             + event(at: now, input: 120, cached: 50, output: 40, reasoning: 10)).write(to: file, atomically: true, encoding: .utf8)
        let counter = CodexUsageCounter()
        var summary = await counter.summary(files: [file], now: now, calendar: calendar)
        XCTAssertEqual(summary.yesterday.total, 100)
        XCTAssertEqual(summary.today, CodexTokens(input: 40, cached: 20, output: 20, reasoning: 5))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(event(at: now, input: 130, cached: 50, output: 45, reasoning: 10).utf8)); try handle.close()
        summary = await counter.summary(files: [file], now: now, calendar: calendar)
        XCTAssertEqual(summary.today.total, 75, "之后只读新增部分")
        XCTAssertEqual(summary.week, 175)
    }
}
