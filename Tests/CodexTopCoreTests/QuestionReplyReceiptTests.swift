import Foundation
import XCTest
@testable import CodexTopCore

final class QuestionReplyReceiptTests: XCTestCase {
    private let thread = "11111111-1111-4111-8111-111111111111"
    private let turn = "33333333-3333-4333-8333-333333333333"
    private let client = "44444444-4444-4444-8444-444444444444"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Unicode 和转义只出现在临时正文，结果保留调用与多题序号而不保留答案。
    func testMultipleQuestionsUnicodeAndEscapesYieldOnlyAssociationMetadata() throws {
        let input = try reply(items: [("call_first", 0), ("call_first", 1), ("call_second-A", 0)],
                              answer: "继续中文调试\n\"引号\" \\ 机器人😀")
        let receipt = try XCTUnwrap(QuestionReplyReceipt.parse(text: "\n " + input + " \n", threadID: thread,
                                                              turnID: turn, clientID: client, receivedAt: now))
        XCTAssertEqual(receipt.threadID, thread)
        XCTAssertEqual(receipt.turnID, turn)
        XCTAssertEqual(receipt.clientID, client)
        XCTAssertEqual(receipt.receivedAt, now)
        XCTAssertEqual(receipt.questionItems, ["call_first": [0, 1], "call_second-A": [0]])
        XCTAssertFalse(String(reflecting: receipt).contains("继续"))
        XCTAssertFalse(String(reflecting: receipt).contains("answer"))
    }

    /// 包装必须占据整条输入，不接受普通消息、代码块或工具日志里的相似片段。
    func testOrdinaryMessagesLogInjectionAndMalformedWrappersFailClosed() throws {
        let valid = try reply()
        let invalid = [
            "普通回复", "请分析：" + valid, valid + "还有一句话", "```\n" + valid + "\n```",
            "Submission { text: \"" + valid + "\" }", valid + valid,
            "<send_user_message_question_reply>invalid JSON</send_user_message_question_reply>",
            "<send_user_message_question_reply>{}</send_user_message_question_reply>",
            "<send_user_message_question_reply>[]</send_user_message_question_reply>",
            String(valid.dropLast()), String(valid.dropFirst()),
            valid.replacingOccurrences(of: "send_user_message_question_reply", with: "user_message")
        ]
        for (index, input) in invalid.enumerated() {
            XCTAssertNil(QuestionReplyReceipt.questionItems(in: input), "Invalid wrapper \(index)")
        }
    }

    /// 非字符串或空答案、非法题号与重复问题均不能产生已回答凭据。
    func testAnswersCallIdentifiersAndQuestionIndexesAreStrictlyValidated() throws {
        for answer: Any in ["", " \n\t", 7, true, NSNull(), ["text": "继续"]] {
            XCTAssertNil(QuestionReplyReceipt.questionItems(in: try reply(answer: answer)))
        }
        for index: Any in [true, false, -1, 0.5, 64, "0", NSNull()] {
            XCTAssertNil(QuestionReplyReceipt.questionItems(in: try reply(rawIndex: index)))
        }
        for call in ["call_", "other_call", "call_has space", "call_injected\nline", "call_" + String(repeating: "x", count: 252)] {
            XCTAssertNil(QuestionReplyReceipt.questionItems(in: try reply(items: [(call, 0)])))
        }
        XCTAssertNil(QuestionReplyReceipt.questionItems(in: try reply(items: [("call_same", 0), ("call_same", 0)])))
        XCTAssertNil(QuestionReplyReceipt.questionItems(in: try reply(tool: "request_user_input")))
        XCTAssertEqual(QuestionReplyReceipt.questionItems(in: try reply(items: [("call_last", 63)])), ["call_last": [63]])
    }

    /// 提交关联标识需完整有效，非法接收时间不能交给归约器。
    func testAssociationIdentifiersAndNonfiniteDatesAreRejected() throws {
        let input = try reply()
        for invalid in ["", "not-a-uuid", thread.replacingOccurrences(of: "-", with: ""), " " + thread, thread + "\n"] {
            XCTAssertNil(QuestionReplyReceipt.parse(text: input, threadID: invalid, turnID: turn, clientID: client, receivedAt: now))
            XCTAssertNil(QuestionReplyReceipt.parse(text: input, threadID: thread, turnID: invalid, clientID: client, receivedAt: now))
            XCTAssertNil(QuestionReplyReceipt.parse(text: input, threadID: thread, turnID: turn, clientID: invalid, receivedAt: now))
        }
        for invalid in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertNil(QuestionReplyReceipt.parse(text: input, threadID: thread, turnID: turn, clientID: client,
                                                   receivedAt: Date(timeIntervalSinceReferenceDate: invalid)))
        }
    }

    /// 限制 UTF-8 字节量与问题总数，防止意外大输入进入辅助解析路径。
    func testInputBytesAndQuestionCountRemainBounded() throws {
        XCTAssertNil(QuestionReplyReceipt.questionItems(in: try reply(answer: String(repeating: "中", count: 22_000))))
        XCTAssertNil(QuestionReplyReceipt.questionItems(in: try reply(items: (0..<65).map { ("call_\($0)", 0) })))
        let maximumItems = try reply(items: (0..<64).map { ("call_\($0)", 0) })
        XCTAssertEqual(QuestionReplyReceipt.questionItems(in: maximumItems)?.count, 64)
    }

    /// 独立生成卡片包装，所有测试均使用合成内容。
    private func reply(items: [(String, Int)] = [("call_first", 0)], answer: Any = "继续", rawIndex: Any? = nil,
                       tool: String = "request_user_input_async") throws -> String {
        let replies = try items.map { call, index -> [String: Any] in
            let key = try JSONSerialization.data(withJSONObject: [tool, call, rawIndex ?? index])
            return ["questionItemId": String(decoding: key, as: UTF8.self), "question": "Synthetic", "answer": answer]
        }
        let data = try JSONSerialization.data(withJSONObject: replies, options: [.withoutEscapingSlashes])
        return "<send_user_message_question_reply>\n\(String(decoding: data, as: UTF8.self))\n</send_user_message_question_reply>"
    }
}
