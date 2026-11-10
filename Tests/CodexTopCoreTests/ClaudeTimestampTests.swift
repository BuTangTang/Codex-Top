import Foundation
import XCTest
@testable import CodexTopCore

/// 只用合成记录验证时间解析优化，保持计时缺失与乱序记录的既有处理。
final class ClaudeTimestampTests: XCTestCase {
    /// 整秒、小数秒及正负时区偏移都指向相同的绝对时间。
    func testTimestampVariantsPreserveInstants() throws {
        let base: TimeInterval = 1_794_187_866
        let cases: [(String, TimeInterval)] = [
            ("2026-11-09T01:31:06Z", base),
            ("2026-11-09T01:31:06.125Z", base + 0.125),
            ("2026-11-09T09:31:06+08:00", base),
            ("2026-11-09T09:31:06.125+08:00", base + 0.125),
            ("2026-11-08T20:31:06-05:00", base),
            ("2026-11-08T20:31:06.5-05:00", base + 0.5)
        ]
        for (timestamp, expected) in cases {
            var reducer = ClaudeTranscriptReducer()
            reducer.consume(try record(timestamp: timestamp))
            XCTAssertEqual(try XCTUnwrap(reducer.activity.startedAt).timeIntervalSince1970, expected, accuracy: 0.0001, timestamp)
            XCTAssertEqual(reducer.activity.lastEventAt, reducer.activity.startedAt, timestamp)
            XCTAssertEqual(reducer.firstEventAt, reducer.activity.startedAt, timestamp)
        }
    }

    /// 缺失或无效时间不生成估算时间；无时间的结束事件仍保留上一条已知活动时间。
    func testMissingAndInvalidTimestampKeepExistingSemantics() throws {
        for timestamp: Any? in [nil, NSNull(), "", "invalid", 42] {
            var fresh = ClaudeTranscriptReducer()
            fresh.consume(try record(timestamp: timestamp))
            XCTAssertEqual(fresh.activity.phase, .running)
            XCTAssertNil(fresh.firstEventAt)
            XCTAssertNil(fresh.activity.startedAt)
            XCTAssertNil(fresh.activity.lastEventAt)

            var started = ClaudeTranscriptReducer()
            started.consume(try record(timestamp: "2026-11-09T01:31:06.125Z"))
            let knownTime = started.activity.lastEventAt
            started.consume(try record(timestamp: timestamp, completed: true))
            XCTAssertEqual(started.activity.phase, .completed)
            XCTAssertEqual(started.activity.startedAt, knownTime)
            XCTAssertEqual(started.activity.lastEventAt, knownTime)
            XCTAssertEqual(started.firstEventAt, knownTime)
        }
    }

    /// 按绝对时间拒绝跨时区的旧记录，新的合法时间仍能开始下一轮。
    func testOlderOffsetTimestampCannotReopenCompletedTurn() throws {
        var reducer = ClaudeTranscriptReducer()
        reducer.consume(try record(timestamp: "2026-11-09T01:31:06.125Z"))
        reducer.consume(try record(timestamp: "2026-11-09T09:31:36+08:00", completed: true))
        let completed = reducer.activity
        reducer.consume(try record(timestamp: "2026-11-08T20:31:35.999-05:00"))
        XCTAssertEqual(reducer.activity, completed)
        reducer.consume(try record(timestamp: "2026-11-08T20:31:37-05:00"))
        XCTAssertEqual(reducer.activity.phase, .running)
        XCTAssertEqual(try XCTUnwrap(reducer.activity.startedAt).timeIntervalSince1970, 1_794_187_897, accuracy: 0.0001)
    }

    /// 生成不含真实正文的起始或结束记录；省略时间与非字符串时间分别保留原始输入类型。
    private func record(timestamp: Any?, completed: Bool = false) throws -> Data {
        var value: [String: Any] = ["type": completed ? "assistant" : "user"]
        if let timestamp { value["timestamp"] = timestamp }
        value["message"] = completed
            ? ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "done"]]]
            : ["role": "user", "content": "synthetic"]
        return try JSONSerialization.data(withJSONObject: value)
    }
}
