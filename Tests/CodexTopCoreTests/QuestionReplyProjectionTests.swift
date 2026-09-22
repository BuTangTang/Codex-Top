import Foundation
import XCTest
@testable import CodexTopCore

final class QuestionReplyProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let thread = "00000000-0000-4000-8000-000000000001"
    private let turn = "00000000-0000-4000-8000-000000000002"

    /// 构造独立合成事件，不读取用户任务或原始日志。
    private func event(_ type: String, seconds: Double, kind: String = "event_msg", extra: [String: Any] = [:]) throws -> Data {
        var payload = extra
        payload["type"] = type
        return try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)), "type": kind, "payload": payload])
    }

    /// 模拟具有明确轮次和一组异步问题的任务。
    private func asking(count: Int = 1) throws -> RolloutReducer {
        var reducer = RolloutReducer()
        reducer.consume(try event("task_started", seconds: 0, extra: ["turn_id": turn]))
        try ask(&reducer, call: "call_first", count: count, seconds: 10)
        return reducer
    }

    /// 追加问题并只让归约器保存索引，不依赖正文判断状态。
    private func ask(_ reducer: inout RolloutReducer, call: String, count: Int, seconds: Double) throws {
        let data = try JSONSerialization.data(withJSONObject: ["questions": (0..<count).map { ["title": "合成问题 \($0)"] }])
        reducer.consume(try event("function_call", seconds: seconds, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": call, "arguments": String(decoding: data, as: UTF8.self)]))
    }

    /// 构造上游已验证的接收回执，仅包含匹配所需元数据。
    private func receipt(threadID: String? = nil, turnID: String? = nil, call: String = "call_first", items: Set<Int> = [0], seconds: Double = 20) -> QuestionReplyReceipt {
        QuestionReplyReceipt(threadID: threadID ?? thread, turnID: turnID ?? turn, clientID: "00000000-0000-4000-8000-000000000003", receivedAt: start.addingTimeInterval(seconds), questionItems: [call: items])
    }

    /// 正式历史晚到 96 秒时，接收证据先解除黄色，且不改真实状态和计时锚点。
    func testReceiptProjectsReplyBeforeDelayedHistoryWithoutMutatingReducer() throws {
        let reducer = try asking()
        let original = reducer.activity
        let shown = reducer.activity(acknowledging: [receipt()], for: thread, at: start.addingTimeInterval(21))
        XCTAssertEqual(shown.phase, .running)
        XCTAssertEqual(shown.detail, "已回复，等待继续")
        XCTAssertNil(shown.waitingStartedAt)
        XCTAssertEqual(shown.startedAt, original.startedAt)
        XCTAssertEqual(shown.lastEventAt, original.lastEventAt)
        XCTAssertEqual(shown.turnID, original.turnID)
        XCTAssertEqual(reducer.activity, original)
    }

    /// 不接受其他任务、轮次、问题、提问前或未来的回执。
    func testMismatchedAndImpossibleReceiptsKeepWaiting() throws {
        let reducer = try asking()
        for item in [receipt(threadID: "other"), receipt(turnID: "other"), receipt(call: "call_other"), receipt(items: [1]), receipt(seconds: 9), receipt(seconds: 100)] {
            XCTAssertEqual(reducer.activity(acknowledging: [item], for: thread, at: start.addingTimeInterval(21)).phase, .waiting)
        }
    }

    /// 一组问题只有全部被回答才解除等待，重复序号不能补齐缺失回答。
    func testPartialAndDuplicateAnswersDoNotClearOtherItems() throws {
        let reducer = try asking(count: 2)
        XCTAssertEqual(reducer.activity(acknowledging: [receipt(), receipt()], for: thread, at: start.addingTimeInterval(21)).phase, .waiting)
        XCTAssertEqual(reducer.activity(acknowledging: [receipt(), receipt(items: [1])], for: thread, at: start.addingTimeInterval(21)).phase, .running)
    }

    /// 同轮新提问不会被之前已经接收的回答误清除。
    func testNewQuestionRequiresItsOwnReply() throws {
        var reducer = try asking()
        try ask(&reducer, call: "call_second", count: 1, seconds: 25)
        XCTAssertEqual(reducer.activity(acknowledging: [receipt()], for: thread, at: start.addingTimeInterval(40)).phase, .waiting)
        XCTAssertEqual(reducer.activity(acknowledging: [receipt(), receipt(call: "call_second", seconds: 30)], for: thread, at: start.addingTimeInterval(40)).phase, .running)
    }

    /// 同步问题、审批和未知输入请求优先保留待处理提示。
    func testOtherWaitingReasonsCannotBeClearedByAsyncReply() throws {
        for type in ["exec_approval_request", "apply_patch_approval_request", "user_input_requested"] {
            var reducer = try asking()
            reducer.consume(try event(type, seconds: 15))
            XCTAssertNil(reducer.awaitingReplySince)
            XCTAssertEqual(reducer.activity(acknowledging: [receipt()], for: thread, at: start.addingTimeInterval(21)).phase, .waiting)
        }
        var reducer = try asking()
        reducer.consume(try event("function_call", seconds: 15, kind: "response_item", extra: ["name": "request_user_input", "call_id": "sync"]))
        XCTAssertEqual(reducer.activity(acknowledging: [receipt()], for: thread, at: start.addingTimeInterval(21)).phase, .waiting)
    }

    /// 正式用户事件、停止、失败和轮次结束后，辅助回执不再覆盖真实状态。
    func testAuthoritativeEventsWinOverCachedReceipt() throws {
        for type in ["user_message", "turn_aborted", "task_failed", "task_complete"] {
            var reducer = try asking()
            reducer.consume(try event(type, seconds: 30, extra: ["turn_id": turn]))
            XCTAssertNil(reducer.awaitingReplySince, type)
            XCTAssertEqual(reducer.activity(acknowledging: [receipt()], for: thread, at: start.addingTimeInterval(31)), reducer.activity.effective(at: start.addingTimeInterval(31)), type)
        }
    }

    /// 老问题刚收到回复可以展示，长期无后续活动则显式转未知，不伪造活动时间。
    func testReceiptFreshnessDoesNotInventExecutionTimestamp() throws {
        let reducer = try asking()
        let fresh = reducer.activity(acknowledging: [receipt(seconds: 2_000)], for: thread, at: start.addingTimeInterval(2_001))
        XCTAssertEqual(fresh.phase, .running)
        XCTAssertEqual(fresh.lastEventAt, reducer.activity.lastEventAt)
        let stale = reducer.activity(acknowledging: [receipt()], for: thread, at: start.addingTimeInterval(1_000))
        XCTAssertEqual(stale.phase, .unknown)
        XCTAssertEqual(stale.detail, "已回复，较久未收到后续活动")
    }

    /// 缺少问题数量或当前轮次时，保留现有等待状态。
    func testMissingQuestionMetadataFailsClosed() throws {
        var reducer = RolloutReducer()
        reducer.consume(try event("function_call", seconds: 10, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "call_first"]))
        XCTAssertNil(reducer.awaitingReplySince)
        XCTAssertEqual(reducer.activity(acknowledging: [receipt()], for: thread, at: start.addingTimeInterval(21)).phase, .waiting)
    }

    /// 旧回答不能匹配重新开始的轮次，即使重用了问题编号。
    func testOldTurnReceiptCannotAffectNewTurn() throws {
        var reducer = try asking()
        reducer.consume(try event("task_started", seconds: 25, extra: ["turn_id": "new-turn"]))
        try ask(&reducer, call: "call_first", count: 1, seconds: 30)
        XCTAssertEqual(reducer.activity(acknowledging: [receipt(seconds: 35)], for: thread, at: start.addingTimeInterval(40)).phase, .waiting)
    }
}
