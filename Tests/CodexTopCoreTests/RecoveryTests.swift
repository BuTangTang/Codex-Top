import Foundation
import XCTest
import CSQLite
@testable import CodexTopCore

final class RecoveryTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ type: String, seconds: Double? = 0, kind: String = "event_msg", extra: [String: Any] = [:]) throws -> Data {
        var payload = extra; payload["type"] = type
        var record: [String: Any] = ["type": kind, "payload": payload]
        if let seconds { record["timestamp"] = ISO8601DateFormatter().string(from: time.addingTimeInterval(seconds)) }
        return try JSONSerialization.data(withJSONObject: record)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func contents(prefix: [Data], suffix: [Data], padding: Int = 8_192) -> Data {
        prefix.reduce(into: Data()) { $0.append($1 + Data([10])) }
            + Data(repeating: 120, count: padding) + Data([10])
            + suffix.reduce(into: Data()) { $0.append($1 + Data([10])) }
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    @discardableResult private func finish(_ reader: inout IncrementalRollout, file: URL, budget: Int = 1_024) throws -> Int {
        var total = 0
        for _ in 0..<100 {
            let offset = reader.offset
            let bytes = try reader.recoverTiming(url: file, maximumBytes: budget)
            XCTAssertLessThanOrEqual(bytes, budget)
            XCTAssertEqual(reader.offset, offset, "Historical recovery must not move the primary cursor")
            total += bytes
            if bytes == 0 || reader.reducer.activity.startedAt != nil { return total }
        }
        XCTFail("Synthetic recovery did not finish within its bounded iterations")
        return total
    }

    func testProgressiveRecoveryPreservesNewWritesPartialLineAndOutstandingQuestions() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        let data = try contents(prefix: [event("task_started", extra: ["turn_id": "current"])], suffix: [
            event("function_call", seconds: 20, kind: "response_item", extra: ["name": "request_user_input", "call_id": "one"]),
            event("function_call", seconds: 21, kind: "response_item", extra: ["name": "request_user_input", "call_id": "two"])
        ])
        try data.write(to: file)
        var reader = IncrementalRollout(maximumRead: 1_024)
        XCTAssertEqual(try reader.refresh(url: file), 1_024)
        XCTAssertNil(reader.reducer.activity.startedAt)
        XCTAssertEqual(try reader.recoverTiming(url: file, maximumBytes: 1_024), 1_024)
        XCTAssertNil(reader.reducer.activity.startedAt)

        let partialReply = try event("function_call_output", seconds: 40, kind: "response_item", extra: ["call_id": "two"])
        try append(event("function_call_output", seconds: 30, kind: "response_item", extra: ["call_id": "one"]) + Data([10]) + partialReply, to: file)
        _ = try reader.refresh(url: file)
        let last = reader.reducer.activity.lastEventAt
        let bytes = try finish(&reader, file: file)
        XCTAssertGreaterThan(bytes, 1_024)
        XCTAssertEqual(reader.reducer.activity.phase, .waiting)
        XCTAssertEqual(reader.reducer.activity.lastEventAt, last)
        XCTAssertEqual(reader.reducer.activity.startedAt, time)
        XCTAssertEqual(reader.reducer.activity.turnID, "current")
        XCTAssertEqual(reader.reducer.activity.waitingElapsedSeconds, 20)
        try append(Data([10]), to: file)
        XCTAssertEqual(try reader.refresh(url: file), 1)
        XCTAssertEqual(reader.reducer.activity.phase, .running, "Recovery must retain the primary reader's pending line and remaining call ID")
        XCTAssertNil(reader.reducer.activity.waitingStartedAt)
    }

    func testAsyncWaitAndTrailingCompletionKeepCurrentStart() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        try contents(prefix: [event("task_started", extra: ["turn_id": "current"])], suffix: [
            event("function_call", seconds: 10, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "question"]),
            event("task_complete", seconds: 20, extra: ["turn_id": "current"])
        ]).write(to: file)
        var reader = IncrementalRollout(maximumRead: 1_024)
        _ = try reader.refresh(url: file)
        try finish(&reader, file: file)
        XCTAssertEqual(reader.reducer.activity.phase, .waiting)
        XCTAssertEqual(reader.reducer.activity.waitingElapsedSeconds, 10)
        try append(event("function_call_output", seconds: 30, kind: "response_item", extra: ["call_id": "question"]) + Data([10]), to: file)
        _ = try reader.refresh(url: file)
        XCTAssertEqual(reader.reducer.activity.phase, .waiting, "Recovery must not clear the primary asynchronous question")
    }

    func testReplayDistinguishesOldTerminalUserContinuationAndWaitWithoutNewStart() throws {
        let cases: [([Data], [Data], Date?, String?)] = try [
            ([event("task_started", extra: ["turn_id": "current"]), event("task_complete", seconds: 10, extra: ["turn_id": "old"])],
             [event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"])], time, "current"),
            ([event("task_started", extra: ["turn_id": "old"]), event("task_failed", seconds: 10), event("message", seconds: 20, kind: "response_item", extra: ["role": "user"])],
             [event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"])], time.addingTimeInterval(20), nil),
            ([event("task_started", extra: ["turn_id": "old"]), event("task_complete", seconds: 10)],
             [event("exec_approval_request", seconds: 30)], nil, nil)
        ]
        for (prefix, suffix, expectedStart, expectedTurn) in cases {
            let file = try directory().appendingPathComponent("rollout.jsonl")
            try contents(prefix: prefix, suffix: suffix).write(to: file)
            var reader = IncrementalRollout(maximumRead: 1_024)
            _ = try reader.refresh(url: file)
            let original = reader.reducer.activity
            try finish(&reader, file: file)
            XCTAssertEqual(reader.reducer.activity.startedAt, expectedStart)
            XCTAssertEqual(reader.reducer.activity.turnID, expectedTurn)
            XCTAssertEqual(reader.reducer.activity.phase, original.phase)
            XCTAssertEqual(reader.reducer.activity.lastEventAt, original.lastEventAt)
        }
    }

    func testNearestStartWithoutTimestampCannotBorrowOlderStart() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        try contents(prefix: [
            event("task_started", extra: ["turn_id": "old"]),
            event("task_complete", seconds: 10),
            event("task_started", seconds: nil, extra: ["turn_id": "current"])
        ], suffix: [event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"])]).write(to: file)
        var reader = IncrementalRollout(maximumRead: 1_024)
        _ = try reader.refresh(url: file)
        try finish(&reader, file: file)
        XCTAssertNil(reader.reducer.activity.startedAt)
        XCTAssertEqual(try reader.recoverTiming(url: file, maximumBytes: 1_024), 0)
    }

    func testSearchWithoutStartIsCachedAcrossOrdinaryAppends() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        try contents(prefix: [], suffix: [event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"])]).write(to: file)
        var reader = IncrementalRollout(maximumRead: 1_024)
        _ = try reader.refresh(url: file)
        try finish(&reader, file: file)
        XCTAssertNil(reader.reducer.activity.startedAt)
        for second in [40.0, 50.0] {
            try append(event("function_call", seconds: second, kind: "response_item", extra: ["name": "work"]) + Data([10]), to: file)
            _ = try reader.refresh(url: file)
            XCTAssertEqual(try reader.recoverTiming(url: file, maximumBytes: 1_024), 0)
        }
    }

    func testReplacementAndSameSizeRewriteResetCachedFailure() throws {
        for replaceInode in [true, false] {
            let root = try directory(), file = root.appendingPathComponent("rollout.jsonl")
            let initial = try contents(prefix: [event("agent_message")], suffix: [event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"])])
            try initial.write(to: file)
            var reader = IncrementalRollout(maximumRead: 1_024)
            _ = try reader.refresh(url: file); try finish(&reader, file: file)
            XCTAssertNil(reader.reducer.activity.startedAt)
            let replacementPrefix = try event("task_started", seconds: 10, extra: ["turn_id": "new"])
            var replacement = contents(prefix: [replacementPrefix], suffix: [])
            replacement.append(try event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"]) + Data([10]))
            // Equal size makes this a rewrite check rather than a shrink/inode shortcut.
            let size = max(initial.count, replacement.count)
            if initial.count < size {
                try append(Data(repeating: 32, count: size - initial.count), to: file)
                _ = try reader.refresh(url: file)
            }
            if replacement.count < size { replacement.append(Data(repeating: 32, count: size - replacement.count)) }
            if replaceInode {
                try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("old.jsonl"))
                try replacement.write(to: file)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                try handle.write(contentsOf: replacement); try handle.truncate(atOffset: UInt64(replacement.count)); try handle.close()
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
            }
            _ = try reader.refresh(url: file)
            try finish(&reader, file: file)
            XCTAssertEqual(reader.reducer.activity.startedAt, time.addingTimeInterval(10))
            XCTAssertEqual(reader.reducer.activity.turnID, "new")
        }
    }

    func testNewObservedTurnCancelsInProgressRecovery() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        try contents(prefix: [event("task_started", extra: ["turn_id": "old"])], suffix: [event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"])]).write(to: file)
        var reader = IncrementalRollout(maximumRead: 1_024)
        _ = try reader.refresh(url: file)
        XCTAssertEqual(try reader.recoverTiming(url: file, maximumBytes: 1_024), 1_024)
        try append(event("task_started", seconds: 40, extra: ["turn_id": "new"]) + Data([10]), to: file)
        _ = try reader.refresh(url: file)
        XCTAssertEqual(try reader.recoverTiming(url: file, maximumBytes: 1_024), 0)
        XCTAssertEqual(reader.reducer.activity.startedAt, time.addingTimeInterval(40))
        XCTAssertEqual(reader.reducer.activity.turnID, "new")
    }

    func testSourceRecoversOnlySelectedRootAndItsDescendants() async throws {
        let root = try directory()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT);", nil, nil, nil), SQLITE_OK)
        for (index, id) in ["root", "child", "grandchild", "unselected"].enumerated() {
            let file = root.appendingPathComponent(id + ".jsonl")
            try contents(prefix: [event("task_started", seconds: Double(index), extra: ["turn_id": id])], suffix: [
                event("function_call", seconds: 30, kind: "response_item", extra: ["name": "work"])
            ], padding: 70_000).write(to: file)
            let sql = "INSERT INTO threads VALUES('\(id)','Synthetic','/example','\(file.path)',1,2,0);"
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO thread_spawn_edges VALUES('root','child'); INSERT INTO thread_spawn_edges VALUES('child','grandchild');", nil, nil, nil), SQLITE_OK)
        let source = LocalCodexSource(root: root)
        let cold = try await source.snapshot(now: time.addingTimeInterval(40))
        XCTAssertTrue(cold.tasks.allSatisfy { $0.activity.startedAt == nil })
        let selected = try await source.snapshot(now: time.addingTimeInterval(40), recoverTimingFor: ["root"])
        XCTAssertGreaterThan(selected.bytesRead, 0, "Recovery I/O must be included in the snapshot byte count")
        for (index, id) in ["root", "child", "grandchild"].enumerated() {
            XCTAssertEqual(selected.tasks.first(where: { $0.id == id })?.activity.startedAt, time.addingTimeInterval(Double(index)))
        }
        XCTAssertNil(selected.tasks.first(where: { $0.id == "unselected" })?.activity.startedAt)
        let unchanged = try await source.snapshot(now: time.addingTimeInterval(40), recoverTimingFor: ["root"])
        XCTAssertEqual(unchanged.bytesRead, 0)
    }
}
