import Foundation
import XCTest
@testable import CodexTopCore

final class ReplyContinuationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ type: String, seconds: Double = 0, kind: String = "event_msg", extra: [String: Any] = [:]) throws -> Data {
        var payload = extra
        payload["type"] = type
        return try JSONSerialization.data(withJSONObject: [
            "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)),
            "type": kind, "payload": payload
        ])
    }

    private func beginAsyncWait(_ reducer: inout RolloutReducer) throws {
        reducer.consume(try event("task_started", extra: ["turn_id": "current"]))
        reducer.consume(try event("function_call", seconds: 10, kind: "response_item",
                                  extra: ["name": "request_user_input_async", "call_id": "async-question"]))
    }

    func testResponseUserMessageResumesAsyncWaitBeforeUserMessageEvent() throws {
        var reducer = RolloutReducer()
        try beginAsyncWait(&reducer)
        // Async tool output and its trailing completion still require a user's answer.
        reducer.consume(try event("function_call_output", seconds: 11, kind: "response_item", extra: ["call_id": "async-question"]))
        reducer.consume(try event("task_complete", seconds: 12, extra: ["turn_id": "current"]))
        XCTAssertEqual(reducer.activity.phase, .waiting)
        XCTAssertEqual(reducer.activity.waitingStartedAt, start.addingTimeInterval(10))

        reducer.consume(try event("message", seconds: 20, kind: "response_item", extra: ["role": "user"]))
        XCTAssertEqual(reducer.activity.phase, .running)
        XCTAssertEqual(reducer.activity.startedAt, start)
        XCTAssertEqual(reducer.activity.turnID, "current")
        XCTAssertEqual(reducer.activity.lastEventAt, start.addingTimeInterval(20))
        XCTAssertNil(reducer.activity.waitingStartedAt)
        XCTAssertNil(reducer.activity.waitingElapsedSeconds)

        // No later item_completed(UserMessage) is required to clear the async flag.
        reducer.consume(try event("task_complete", seconds: 30, extra: ["turn_id": "current"]))
        XCTAssertEqual(reducer.activity.phase, .completed)
    }

    func testNonUserMessagesAndOrdinaryToolReturnsPreserveAsyncWait() throws {
        var reducer = RolloutReducer()
        try beginAsyncWait(&reducer)
        for (index, role) in ["assistant", "developer", "tool", "system", ""].enumerated() {
            let extra: [String: Any] = role.isEmpty ? [:] : ["role": role]
            reducer.consume(try event("message", seconds: Double(20 + index), kind: "response_item", extra: extra))
            XCTAssertEqual(reducer.activity.phase, .waiting, role)
            XCTAssertEqual(reducer.activity.waitingStartedAt, start.addingTimeInterval(10), role)
        }
        reducer.consume(try event("function_call", seconds: 30, kind: "response_item", extra: ["name": "ordinary_tool", "call_id": "other"]))
        for (index, id) in ["other", "async-question"].enumerated() {
            reducer.consume(try event("function_call_output", seconds: Double(31 + index), kind: "response_item", extra: ["call_id": id]))
            XCTAssertEqual(reducer.activity.phase, .waiting, id)
            XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 10, id)
        }
    }

    func testResponseUserMessageClearsOutstandingQuestionIDs() throws {
        var reducer = RolloutReducer()
        try beginAsyncWait(&reducer)
        for (index, id) in ["old-one", "old-two"].enumerated() {
            reducer.consume(try event("function_call", seconds: Double(11 + index), kind: "response_item",
                                      extra: ["name": "request_user_input", "call_id": id]))
        }
        reducer.consume(try event("message", seconds: 20, kind: "response_item", extra: ["role": "user"]))
        XCTAssertEqual(reducer.activity.phase, .running)
        reducer.consume(try event("function_call", seconds: 30, kind: "response_item",
                                  extra: ["name": "request_user_input", "call_id": "new-question"]))
        XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 30)
        reducer.consume(try event("function_call_output", seconds: 40, kind: "response_item", extra: ["call_id": "new-question"]))
        XCTAssertEqual(reducer.activity.phase, .running, "Old question IDs or the async flag must not block the new answer")
        XCTAssertNil(reducer.activity.waitingStartedAt)
    }

    func testResponseUserMessageResumesTerminalStateButRejectsHistoricalMessage() throws {
        let terminals: [(String, TaskPhase)] = [("task_failed", .failed), ("task_complete", .completed), ("turn_aborted", .stopped)]
        for (type, phase) in terminals {
            var reducer = RolloutReducer()
            reducer.consume(try event("task_started", extra: ["turn_id": "old-turn"]))
            reducer.consume(try event(type, seconds: 10, extra: ["turn_id": "old-turn"]))
            reducer.consume(try event("message", seconds: 5, kind: "response_item", extra: ["role": "user"]))
            XCTAssertEqual(reducer.activity.phase, phase, type)
            XCTAssertEqual(reducer.activity.lastEventAt, start.addingTimeInterval(10), type)

            reducer.consume(try event("message", seconds: 20, kind: "response_item", extra: ["role": "user"]))
            XCTAssertEqual(reducer.activity.phase, .running, type)
            XCTAssertEqual(reducer.activity.startedAt, start.addingTimeInterval(20), type)
            XCTAssertNil(reducer.activity.turnID, type)
            XCTAssertNil(reducer.activity.waitingStartedAt, type)
        }
    }

    func testIncrementalReplyResumesOnItsFirstCompletedLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-reply-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let initial = try event("task_started", extra: ["turn_id": "current"]) + Data([10])
            + event("function_call", seconds: 10, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "question"]) + Data([10])
        try initial.write(to: file)
        var reader = IncrementalRollout()
        _ = try reader.refresh(url: file)
        XCTAssertEqual(reader.reducer.activity.phase, .waiting)

        let reply = try event("message", seconds: 20, kind: "response_item", extra: ["role": "user"])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: reply)
        _ = try reader.refresh(url: file)
        XCTAssertEqual(reader.reducer.activity.phase, .waiting, "A partial line cannot be treated as a completed reply")
        try handle.write(contentsOf: Data([10]))
        XCTAssertEqual(try reader.refresh(url: file), 1)
        XCTAssertTrue(reader.isCaughtUp)
        XCTAssertEqual(reader.reducer.activity.phase, .running)
        XCTAssertEqual(reader.reducer.activity.startedAt, start)
        XCTAssertEqual(reader.reducer.activity.turnID, "current")
        XCTAssertNil(reader.reducer.activity.waitingStartedAt)
        XCTAssertEqual(try reader.refresh(url: file), 0)
    }
}
