import Foundation
import CoreFoundation

/// 接收来源验证成功后交给归约器的关联元数据；不保存问题、答案或原始消息。
public struct QuestionReplyReceipt: Sendable, Equatable {
    public let threadID: String
    public let turnID: String
    public let clientID: String
    public let receivedAt: Date
    public let questionItems: [String: Set<Int>]

    /// 创建供归约器按任务、轮次、调用和问题序号校验的接收凭据。
    public init(threadID: String, turnID: String, clientID: String, receivedAt: Date,
                questionItems: [String: Set<Int>]) {
        self.threadID = threadID; self.turnID = turnID; self.clientID = clientID
        self.receivedAt = receivedAt; self.questionItems = questionItems
    }

    /// 严格解析已接收消息的标识及卡片包装；来源负责验证 accepted 和接收时间不在未来。
    public static func parse(text: String, threadID: String, turnID: String,
                             clientID: String, receivedAt: Date) -> QuestionReplyReceipt? {
        guard isUUID(threadID), isUUID(turnID), isUUID(clientID),
              receivedAt.timeIntervalSince1970.isFinite,
              let items = questionItems(in: text) else { return nil }
        return QuestionReplyReceipt(threadID: threadID, turnID: turnID, clientID: clientID,
                                    receivedAt: receivedAt, questionItems: items)
    }

    /// 仅识别完整卡片回答，验证答案类型后丢弃正文，拒绝普通消息中粘贴的包装片段。
    public static func questionItems(in text: String) -> [String: Set<Int>]? {
        guard text.utf8.count <= 65_536 else { return nil }
        let opening = "<send_user_message_question_reply>", closing = "</send_user_message_question_reply>"
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(opening), value.hasSuffix(closing) else { return nil }
        let json = String(value.dropFirst(opening.count).dropLast(closing.count))
        guard let data = json.data(using: .utf8),
              let answers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !answers.isEmpty, answers.count <= 64 else { return nil }
        var result: [String: Set<Int>] = [:]
        for answer in answers {
            guard let body = answer["answer"] as? String,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let item = answer["questionItemId"] as? String,
                  let bytes = item.data(using: .utf8),
                  let parts = try? JSONSerialization.jsonObject(with: bytes) as? [Any], parts.count == 3,
                  parts[0] as? String == "request_user_input_async", let call = parts[1] as? String,
                  call.hasPrefix("call_"), call.utf8.count > 5, call.utf8.count <= 256,
                  call.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }),
                  let index = parts[2] as? NSNumber, CFGetTypeID(index) != CFBooleanGetTypeID(),
                  index.doubleValue.isFinite, index.doubleValue >= 0, index.doubleValue < 64,
                  index.doubleValue.rounded(.down) == index.doubleValue else { return nil }
            // 重复题号可能包含互相矛盾的答案，不能用集合静默吞掉歧义。
            guard result[call, default: []].insert(index.intValue).inserted else { return nil }
        }
        return result
    }

    /// 标识必须是规范 UUID 形状，拒绝额外分隔符或缺少连字符的宽松表示。
    private static func isUUID(_ text: String) -> Bool {
        text.utf8.count == 36 && UUID(uuidString: text) != nil
    }
}
