import Foundation
import XCTest
import CSQLite
@testable import CodexTopCore

final class LongWaitReplyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ type: String, at seconds: Double, kind: String = "event_msg", extra: [String: Any] = [:]) throws -> Data {
        var payload = extra
        payload["type"] = type
        return try JSONSerialization.data(withJSONObject: [
            "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)),
            "type": kind, "payload": payload
        ]) + Data([10])
    }

    private func question(_ id: String, at seconds: Double) throws -> Data {
        try record("function_call", at: seconds, kind: "response_item",
                   extra: ["name": "request_user_input_async", "call_id": id])
    }

    private func reply(_ id: String, at seconds: Double) throws -> Data {
        let itemID = String(decoding: try JSONSerialization.data(withJSONObject: ["request_user_input_async", id, 0]), as: UTF8.self)
        let answers = try JSONSerialization.data(withJSONObject: [["questionItemId": itemID, "question": "Synthetic question", "answer": "Synthetic answer"]])
        let text = "<send_user_message_question_reply>\n\(String(decoding: answers, as: UTF8.self))\n</send_user_message_question_reply>"
        return try record("message", at: seconds, kind: "response_item",
                          extra: ["role": "user", "content": [["type": "input_text", "text": text]]])
    }

    private func fixture() throws -> (LocalCodexSource, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-long-wait-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("rollout.jsonl")
        try (record("task_started", at: 0, extra: ["turn_id": "current"]) + question("first", at: 10)).write(to: log)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER);
        INSERT INTO threads VALUES('fixture','Synthetic','/example','\(log.path)',1,2,0);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        return (LocalCodexSource(root: root), log)
    }

    private func append(_ data: Data, to log: URL) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testLongIdleSnapshotsDoNotPreventAnySupportedUserReplyFromClearingWait() async throws {
        // Advance observation/event times, without sleeping or changing the system clock.
        for delay in [1_200.0, 7_200.0, 86_400.0] {
            let replies = try [
                reply("first", at: delay),
                record("user_message", at: delay),
                record("item_completed", at: delay, extra: ["item": ["type": "UserMessage"]])
            ]
            for answer in replies {
                let (source, log) = try fixture()
                let initial = try await source.snapshot(now: start.addingTimeInterval(10))
                XCTAssertEqual(initial.tasks.first?.activity.phase, .waiting)
                for elapsed in [delay / 2, delay - 1] {
                    let idle = try await source.snapshot(now: start.addingTimeInterval(elapsed))
                    XCTAssertEqual(idle.bytesRead, 0)
                    XCTAssertEqual(idle.tasks.first?.activity.phase, .waiting)
                    XCTAssertEqual(idle.tasks.first?.activity.waitingElapsedSeconds, 10)
                }

                // Database timestamps remain old: an appended answer must still be read.
                try append(answer, to: log)
                let resumed = try await source.snapshot(now: start.addingTimeInterval(delay))
                let activity = try XCTUnwrap(resumed.tasks.first?.activity)
                XCTAssertEqual(resumed.bytesRead, answer.count)
                XCTAssertEqual(activity.phase, .running)
                XCTAssertEqual(activity.startedAt, start)
                XCTAssertEqual(activity.turnID, "current")
                XCTAssertEqual(activity.lastEventAt, start.addingTimeInterval(delay))
                XCTAssertNil(activity.waitingStartedAt)
            }
        }
    }

    func testLongWaitReplyBehindReadBudgetClearsAsSoonAsSourceCatchesUp() async throws {
        let (source, log) = try fixture()
        _ = try await source.snapshot(now: start.addingTimeInterval(10))
        let budget = 4 * 1_024 * 1_024
        let burst = try record("function_call_output", at: 7_199, kind: "response_item",
                               extra: ["call_id": "ordinary-tool", "output": String(repeating: "x", count: budget)])
            + reply("first", at: 7_200)
        try append(burst, to: log)
        let behind = try await source.snapshot(now: start.addingTimeInterval(7_200))
        XCTAssertEqual(behind.bytesRead, budget)
        XCTAssertEqual(behind.tasks.first?.activity.phase, .unknown)
        XCTAssertEqual(behind.tasks.first?.activity.detail, "正在同步任务活动…")

        let caughtUp = try await source.snapshot(now: start.addingTimeInterval(7_201))
        XCTAssertEqual(caughtUp.bytesRead, burst.count - budget)
        XCTAssertEqual(caughtUp.tasks.first?.activity.phase, .running)
        XCTAssertEqual(caughtUp.tasks.first?.activity.turnID, "current")
        XCTAssertNil(caughtUp.tasks.first?.activity.waitingStartedAt)
    }

    func testFreshQuestionAfterDelayedReplyUsesItsOwnWaitAndClearsIndependently() async throws {
        let (source, log) = try fixture()
        _ = try await source.snapshot(now: start.addingTimeInterval(10))
        // Both changes may land between snapshots: the visible wait is the new question.
        try append(reply("first", at: 7_200) + question("second", at: 7_209), to: log)
        let renewed = try await source.snapshot(now: start.addingTimeInterval(7_210))
        XCTAssertEqual(renewed.tasks.first?.activity.phase, .waiting)
        XCTAssertEqual(renewed.tasks.first?.activity.waitingElapsedSeconds, 7_209)
        try append(reply("second", at: 7_255), to: log)
        let resumed = try await source.snapshot(now: start.addingTimeInterval(7_255))
        XCTAssertEqual(resumed.tasks.first?.activity.phase, .running)
        XCTAssertNil(resumed.tasks.first?.activity.waitingStartedAt)

        try append(record("function_call_output", at: 7_256, kind: "response_item", extra: ["call_id": "second"])
                   + record("task_complete", at: 7_257, extra: ["turn_id": "current"]), to: log)
        let finished = try await source.snapshot(now: start.addingTimeInterval(7_258))
        XCTAssertEqual(finished.tasks.first?.activity.phase, .completed)
    }
}
