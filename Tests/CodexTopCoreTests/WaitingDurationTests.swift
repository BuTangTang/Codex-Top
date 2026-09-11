import Foundation
import XCTest
@testable import CodexTopCore

final class WaitingDurationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ type: String, seconds: Double? = 0, kind: String = "event_msg", extra: [String: Any] = [:]) throws -> Data {
        var payload = extra
        payload["type"] = type
        var record: [String: Any] = ["type": kind, "payload": payload]
        if let seconds { record["timestamp"] = ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)) }
        return try JSONSerialization.data(withJSONObject: record)
    }

    func testAllRecognizedWaitEntriesKeepTheirFirstTimestampAcrossMetadata() throws {
        let entries: [(String, String, [String: Any])] = [
            ("event_msg", "request_user_input", [:]),
            ("event_msg", "user_input_requested", [:]),
            ("event_msg", "exec_approval_request", [:]),
            ("event_msg", "apply_patch_approval_request", [:]),
            ("response_item", "function_call", ["name": "request_user_input", "call_id": "question"]),
            ("response_item", "custom_tool_call", ["name": "request_user_input_async", "call_id": "question"]),
            ("response_item", "function_call", ["name": "tools__request_user_input", "call_id": "question"])
        ]
        for (kind, type, extra) in entries {
            var reducer = RolloutReducer()
            reducer.consume(try event("task_started", extra: ["turn_id": "current"]))
            reducer.consume(try event(type, seconds: 12, kind: kind, extra: extra))
            reducer.consume(try event("function_call_output", seconds: 20, kind: "response_item", extra: ["call_id": "ordinary-output"]))
            reducer.consume(try event("function_call", seconds: 25, kind: "response_item", extra: ["name": "account_usage_read"]))
            reducer.consume(try event("token_count", seconds: 30, extra: ["rate_limits": ["primary": ["used_percent": 20.0, "window_minutes": 300]]]))
            reducer.consume(try event("agent_message", seconds: 35))
            reducer.consume(try event(type, seconds: 40, kind: kind, extra: extra))
            XCTAssertEqual(reducer.activity.phase, .waiting, type)
            XCTAssertEqual(reducer.activity.waitingStartedAt, start.addingTimeInterval(12), type)
            XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 12, type)
            XCTAssertEqual(reducer.activity.lastEventAt, start.addingTimeInterval(40), type)
            XCTAssertEqual(reducer.activity.effective(at: start.addingTimeInterval(10_000)).waitingElapsedSeconds, 12, type)
        }
    }

    func testAnswerClearsAnchorAndAnotherWaitMeasuresFromTheSameTurnStart() throws {
        let replies: [(String, String, [String: Any])] = [
            ("event_msg", "user_message", [:]), ("event_msg", "user_input", [:]),
            ("event_msg", "approval_resolved", [:]),
            ("event_msg", "item_completed", ["item": ["type": "userMessage"]]),
            ("response_item", "function_call_output", ["call_id": "question"])
        ]
        for (kind, type, extra) in replies {
            var reducer = RolloutReducer()
            reducer.consume(try event("task_started", extra: ["turn_id": "first"]))
            reducer.consume(try event("function_call", seconds: 12, kind: "response_item", extra: ["name": "request_user_input", "call_id": "question"]))
            reducer.consume(try event(type, seconds: 50, kind: kind, extra: extra))
            XCTAssertEqual(reducer.activity.phase, .running, type)
            XCTAssertNil(reducer.activity.waitingStartedAt, type)
            XCTAssertNil(reducer.activity.waitingElapsedSeconds, type)
            reducer.consume(try event("exec_approval_request", seconds: 70))
            // The first wait is included in elapsed wall time; this is not accumulated CPU/run time.
            XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 70, type)
            reducer.consume(try event("turn_started", seconds: 100, extra: ["turn_id": "second"]))
            XCTAssertNil(reducer.activity.waitingStartedAt, type)
            reducer.consume(try event("apply_patch_approval_request", seconds: 105))
            XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 5, type)
        }
    }

    func testMultipleQuestionsAndAsyncQuestionDoNotResumeEarly() throws {
        var reducer = RolloutReducer()
        reducer.consume(try event("task_started"))
        reducer.consume(try event("function_call", seconds: 10, kind: "response_item", extra: ["name": "request_user_input", "call_id": "one"]))
        reducer.consume(try event("function_call", seconds: 20, kind: "response_item", extra: ["name": "request_user_input", "call_id": "two"]))
        reducer.consume(try event("function_call_output", seconds: 30, kind: "response_item", extra: ["call_id": "one"]))
        XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 10)
        reducer.consume(try event("function_call_output", seconds: 40, kind: "response_item", extra: ["call_id": "ordinary"]))
        XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 10)
        reducer.consume(try event("function_call_output", seconds: 50, kind: "response_item", extra: ["call_id": "two"]))
        XCTAssertEqual(reducer.activity.phase, .running)
        XCTAssertNil(reducer.activity.waitingStartedAt)

        reducer.consume(try event("function_call", seconds: 60, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "async"]))
        reducer.consume(try event("function_call", seconds: 70, kind: "response_item", extra: ["name": "request_user_input", "call_id": "sync"]))
        reducer.consume(try event("function_call_output", seconds: 80, kind: "response_item", extra: ["call_id": "sync"]))
        XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 60)
        reducer.consume(try event("function_call_output", seconds: 90, kind: "response_item", extra: ["call_id": "async"]))
        XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 60)
        reducer.consume(try event("user_message", seconds: 100))
        XCTAssertEqual(reducer.activity.phase, .running)
        XCTAssertNil(reducer.activity.waitingStartedAt)
    }

    func testAsyncCompletionPreservesTheWaitAnchor() throws {
        var reducer = RolloutReducer()
        reducer.consume(try event("task_started", extra: ["turn_id": "current"]))
        reducer.consume(try event("function_call", seconds: 15, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "question"]))
        for (index, type) in ["task_complete", "turn_complete"].enumerated() {
            reducer.consume(try event(type, seconds: Double(30 + index), extra: ["turn_id": "current"]))
            XCTAssertEqual(reducer.activity.phase, .waiting)
            XCTAssertEqual(reducer.activity.waitingStartedAt, start.addingTimeInterval(15))
            XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 15)
        }
        reducer.consume(try event("item_completed", seconds: 40, extra: ["item": ["type": "userMessage"]]))
        XCTAssertNil(reducer.activity.waitingStartedAt)
    }

    func testMissingFirstWaitTimestampCannotBeInventedByARepeatedWaitOrCompletion() throws {
        var reducer = RolloutReducer()
        reducer.consume(try event("task_started"))
        reducer.consume(try event("function_call", seconds: nil, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "question"]))
        reducer.consume(try event("function_call", seconds: 20, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "question"]))
        reducer.consume(try event("task_complete", seconds: 30))
        XCTAssertEqual(reducer.activity.phase, .waiting)
        XCTAssertNil(reducer.activity.waitingStartedAt)
        XCTAssertNil(reducer.activity.waitingElapsedSeconds)
        reducer.consume(try event("user_input", seconds: 40))
        reducer.consume(try event("user_input_requested", seconds: 50))
        XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 50)

        var missingStart = RolloutReducer()
        missingStart.consume(try event("task_started", seconds: nil))
        missingStart.consume(try event("request_user_input", seconds: 10))
        XCTAssertNil(missingStart.activity.waitingElapsedSeconds)
        var coldTail = RolloutReducer()
        coldTail.consume(try event("exec_approval_request", seconds: 10))
        XCTAssertNil(coldTail.activity.startedAt)
        XCTAssertNil(coldTail.activity.waitingElapsedSeconds)
    }

    func testCurrentTerminalsClearAnchorAndOldTerminalsCannotClearIt() throws {
        for terminal in ["task_complete", "turn_complete", "turn_aborted", "task_cancelled", "turn_cancelled", "task_failed", "turn_failed"] {
            var reducer = RolloutReducer()
            reducer.consume(try event("task_started", extra: ["turn_id": "current"]))
            reducer.consume(try event("request_user_input", seconds: 10))
            reducer.consume(try event(terminal, seconds: 20, extra: ["turn_id": "old"]))
            XCTAssertEqual(reducer.activity.waitingElapsedSeconds, 10, terminal)
            reducer.consume(try event(terminal, seconds: 30, extra: ["turn_id": "current"]))
            XCTAssertNotEqual(reducer.activity.phase, .waiting, terminal)
            XCTAssertNil(reducer.activity.waitingStartedAt, terminal)
            XCTAssertNil(reducer.activity.waitingElapsedSeconds, terminal)
        }
    }

    func testWaitAfterCompletedTurnDoesNotReuseItsOldStart() throws {
        var reducer = RolloutReducer()
        reducer.consume(try event("task_started", extra: ["turn_id": "previous"]))
        reducer.consume(try event("task_complete", seconds: 10, extra: ["turn_id": "previous"]))
        reducer.consume(try event("exec_approval_request", seconds: 20))
        XCTAssertEqual(reducer.activity.phase, .waiting)
        XCTAssertNil(reducer.activity.startedAt)
        XCTAssertNil(reducer.activity.turnID)
        XCTAssertNil(reducer.activity.waitingElapsedSeconds)
    }

    func testChildAggregationRetainsTheChildStartAndWaitAnchor() {
        var parent = CodexTask(id: "parent", title: "Parent", project: "Sample", createdAt: start, updatedAt: start, rolloutURL: URL(fileURLWithPath: "/tmp/parent.jsonl"))
        var child = CodexTask(id: "child", title: "Child", project: "Sample", createdAt: start, updatedAt: start, parentID: "parent", rolloutURL: URL(fileURLWithPath: "/tmp/child.jsonl"))
        parent.activity = TaskActivity(phase: .running, startedAt: start)
        child.activity = TaskActivity(phase: .waiting, lastEventAt: start.addingTimeInterval(80), startedAt: start.addingTimeInterval(20), waitingStartedAt: start.addingTimeInterval(35))
        let aggregated = TaskGraph(tasks: [parent, child]).activity(for: parent)
        XCTAssertEqual(aggregated.waitingElapsedSeconds, 15)
        XCTAssertEqual(aggregated.startedAt, child.activity.startedAt)
        XCTAssertEqual(aggregated.waitingStartedAt, child.activity.waitingStartedAt)
        XCTAssertTrue(aggregated.detail.hasPrefix("子任务"))
    }

    func testDurationRequiresFiniteOrderedAnchorsAndAWaitingPhase() {
        XCTAssertNil(TaskActivity(phase: .waiting, startedAt: start).waitingElapsedSeconds)
        XCTAssertNil(TaskActivity(phase: .waiting, waitingStartedAt: start).waitingElapsedSeconds)
        XCTAssertNil(TaskActivity(phase: .waiting, startedAt: start, waitingStartedAt: start.addingTimeInterval(-1)).waitingElapsedSeconds)
        XCTAssertNil(TaskActivity(phase: .waiting, startedAt: start, waitingStartedAt: Date(timeIntervalSinceReferenceDate: .infinity)).waitingElapsedSeconds)
        XCTAssertNil(TaskActivity(phase: .waiting, startedAt: Date(timeIntervalSinceReferenceDate: .nan), waitingStartedAt: start).waitingElapsedSeconds)
        XCTAssertNil(TaskActivity(phase: .waiting, startedAt: start, waitingStartedAt: Date(timeIntervalSince1970: 1e30)).waitingElapsedSeconds)
        XCTAssertEqual(TaskActivity(phase: .waiting, startedAt: start, waitingStartedAt: start).waitingElapsedSeconds, 0)
        XCTAssertEqual(TaskActivity(phase: .waiting, startedAt: start, waitingStartedAt: start.addingTimeInterval(12.9)).waitingElapsedSeconds, 12)
        for phase in TaskPhase.allCases where phase != .waiting {
            XCTAssertNil(TaskActivity(phase: phase, startedAt: start, waitingStartedAt: start.addingTimeInterval(10)).waitingElapsedSeconds, phase.rawValue)
        }
    }
}
