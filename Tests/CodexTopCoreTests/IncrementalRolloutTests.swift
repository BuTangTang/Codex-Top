import XCTest
import Foundation
import CSQLite
@testable import CodexTopCore

final class IncrementalRolloutTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ type: String, kind: String = "event_msg", extra: [String: Any] = [:]) -> Data {
        var payload = extra; payload["type"] = type
        return try! JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: time),
            "type": kind, "payload": payload])
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-incremental-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func question() -> Data {
        event("task_started", extra: ["turn_id": "current"]) + Data([10])
            + event("function_call", kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "question"]) + Data([10])
    }
    private func outputBurst() -> Data {
        var data = Data()
        for index in 0..<90 {
            data.append(event("function_call", kind: "response_item", extra: ["name": "exec", "call_id": "other-\(index)"]) + Data([10]))
            data.append(event("function_call_output", kind: "response_item", extra: ["call_id": "other-\(index)", "output": String(repeating: "x", count: 1_500)]) + Data([10]))
        }
        return data
    }

    func testWarmOutputBurstPreservesAsyncQuestionUntilUserReply() throws {
        let file = try temporary().appendingPathComponent("rollout.jsonl")
        try question().write(to: file)
        var tail = IncrementalRollout()
        _ = try tail.refresh(url: file)
        XCTAssertEqual(tail.reducer.activity.phase, .waiting)
        let burst = outputBurst()
            + event("function_call_output", kind: "response_item", extra: ["call_id": "question"]) + Data([10])
            + event("token_count", extra: ["rate_limits": ["primary": ["used_percent": 20.0, "window_minutes": 300]]]) + Data([10])
        XCTAssertGreaterThan(burst.count, 65_536)
        try append(burst, to: file)
        XCTAssertEqual(try tail.refresh(url: file), burst.count)
        XCTAssertTrue(tail.isCaughtUp)
        XCTAssertEqual(tail.reducer.activity.phase, .waiting)
        XCTAssertEqual(tail.reducer.activity.turnID, "current")
        XCTAssertEqual(tail.reducer.quota?.fiveHour?.remainingPercent, 80)
        // The app's asynchronous reply is persisted as a UserMessage item, not a tool result.
        try append(event("item_completed", extra: ["item": ["type": "UserMessage"]]) + Data([10]), to: file)
        _ = try tail.refresh(url: file)
        XCTAssertEqual(tail.reducer.activity.phase, .running)
        XCTAssertEqual(try tail.refresh(url: file), 0)
    }

    func testWarmOutputBurstPreservesTurnIDAgainstOldCompletion() throws {
        let file = try temporary().appendingPathComponent("rollout.jsonl")
        try (event("task_started", extra: ["turn_id": "current"]) + Data([10])).write(to: file)
        var tail = IncrementalRollout()
        _ = try tail.refresh(url: file)
        let burst = outputBurst() + event("task_complete", extra: ["turn_id": "old"]) + Data([10])
        try append(burst, to: file)
        XCTAssertEqual(try tail.refresh(url: file), burst.count)
        XCTAssertEqual(tail.reducer.activity.phase, .running)
        XCTAssertEqual(tail.reducer.activity.turnID, "current")
    }

    func testCatchUpBudgetKeepsOrderAndDoesNotParseAnUnfinishedLine() throws {
        let file = try temporary().appendingPathComponent("rollout.jsonl")
        try (event("task_started", extra: ["turn_id": "first"]) + Data([10])).write(to: file)
        var tail = IncrementalRollout(maximumRead: 1_024, maximumCatchUpRead: 2_048)
        _ = try tail.refresh(url: file)
        let completion = event("task_complete", extra: ["turn_id": "second"])
        let split = completion.count / 2
        let padding = Data(repeating: 32, count: 2_047) + Data([10])
        let remaining = event("task_started", extra: ["turn_id": "second"]) + Data([10]) + completion.prefix(split)
        try append(padding + remaining, to: file)
        XCTAssertEqual(try tail.refresh(url: file), 2_048)
        XCTAssertFalse(tail.isCaughtUp)
        XCTAssertEqual(tail.reducer.activity.turnID, "first")
        XCTAssertEqual(try tail.refresh(url: file), remaining.count)
        XCTAssertTrue(tail.isCaughtUp, "The cursor is at the sampled EOF, even though its final line is incomplete")
        XCTAssertEqual(tail.reducer.activity.turnID, "second")
        XCTAssertEqual(tail.reducer.activity.phase, .running)
        try append(completion.dropFirst(split) + Data([10]), to: file)
        _ = try tail.refresh(url: file)
        XCTAssertEqual(tail.reducer.activity.phase, .completed)
        XCTAssertEqual(try tail.refresh(url: file), 0)
    }

    func testRewriteDuringCatchUpUsesObservedSizeInsteadOfCursor() throws {
        for shrink in [false, true] {
            let file = try temporary().appendingPathComponent("rollout.jsonl")
            let initial = question()
            try initial.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
            var tail = IncrementalRollout(maximumRead: 1_024, maximumCatchUpRead: 2_048)
            _ = try tail.refresh(url: file)
            let burst = Data(repeating: 120, count: 4_096) + Data([10])
            try append(burst, to: file)
            try FileManager.default.setAttributes([.modificationDate: time.addingTimeInterval(1)], ofItemAtPath: file.path)
            _ = try tail.refresh(url: file)
            XCTAssertFalse(tail.isCaughtUp)
            XCTAssertEqual(tail.reducer.activity.phase, .waiting)
            let newSize = initial.count + burst.count - (shrink ? 512 : 0)
            XCTAssertGreaterThan(UInt64(newSize), tail.offset, "A truncated file can still extend beyond the cursor")
            let completion = event("task_complete", extra: ["turn_id": "replacement"]) + Data([10])
            let replacement = Data(repeating: 120, count: newSize - completion.count - 1) + Data([10]) + completion
            let writer = try FileHandle(forWritingTo: file)
            try writer.write(contentsOf: replacement)
            try writer.truncate(atOffset: UInt64(newSize)); try writer.close()
            try FileManager.default.setAttributes([.modificationDate: time.addingTimeInterval(2)], ofItemAtPath: file.path)
            XCTAssertLessThanOrEqual(try tail.refresh(url: file), 1_024)
            XCTAssertTrue(tail.isCaughtUp)
            XCTAssertEqual(tail.reducer.activity.phase, .completed, "Same-inode rewrite must discard the old waiting/turn state")
            XCTAssertEqual(try tail.refresh(url: file), 0)
        }
    }

    func testSourcePublishesUnknownWhileCatchingUpWithoutLosingItsQuestion() async throws {
        let root = try temporary(), log = root.appendingPathComponent("rollout.jsonl")
        try question().write(to: log)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        let sql = """
        CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER);
        INSERT INTO threads VALUES('fixture','Synthetic','/example/Synthetic','\(log.path)',1,2,0);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let source = LocalCodexSource(root: root)
        let initial = try await source.snapshot(now: time)
        XCTAssertEqual(initial.tasks.first?.activity.phase, .waiting)
        let budget = 4 * 1_024 * 1_024
        let burst = Data(repeating: 120, count: budget + 1_024) + Data([10])
            + event("function_call", kind: "response_item", extra: ["name": "exec", "call_id": "other"]) + Data([10])
        try append(burst, to: log)
        let behind = try await source.snapshot(now: time)
        XCTAssertEqual(behind.bytesRead, budget)
        XCTAssertEqual(behind.tasks.map(\.id), ["fixture"])
        XCTAssertEqual(behind.tasks.first?.activity.phase, .unknown)
        XCTAssertEqual(behind.tasks.first?.activity.detail, "正在同步任务活动…")
        XCTAssertNil(behind.warning, "A catch-up is task-local and must not add a global warning banner")
        let caughtUp = try await source.snapshot(now: time)
        XCTAssertEqual(caughtUp.bytesRead, burst.count - budget)
        XCTAssertEqual(caughtUp.tasks.first?.activity.phase, .waiting)
        try append(event("item_completed", extra: ["item": ["type": "UserMessage"]]) + Data([10]), to: log)
        let answered = try await source.snapshot(now: time)
        XCTAssertEqual(answered.tasks.first?.activity.phase, .running)
        let unchanged = try await source.snapshot(now: time)
        XCTAssertEqual(unchanged.bytesRead, 0)
    }
}
