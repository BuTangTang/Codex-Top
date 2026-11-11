#include "question_reply_receipt.h"
#include "models/models.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QTimeZone>
#include <cmath>
#include <limits>

namespace codextop {

double QuestionReplyReceipt::receivedReferenceSeconds() const
{
    return preciseReceivedSeconds ? *preciseReceivedSeconds : PreciseTimestamp{receivedAt}.referenceSeconds();
}

bool QuestionReplyReceipt::isUUID(const QString &text)
{
    static const QRegularExpression uuid(QStringLiteral(R"(\A[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\z)"));
    return text.size() == 36 && uuid.match(text).hasMatch();
}

std::optional<QuestionItems> QuestionReplyReceipt::parseQuestionItems(const QString &text)
{
    if (text.size() > 65536 || text.toUtf8().size() > 65536)
        return std::nullopt;
    const auto opening = QStringLiteral("<send_user_message_question_reply>");
    const auto closing = QStringLiteral("</send_user_message_question_reply>");
    const auto value = text.trimmed();
    if (!value.startsWith(opening) || !value.endsWith(closing))
        return std::nullopt;
    const auto json = value.mid(opening.size(), value.size() - opening.size() - closing.size());
    const auto answers = QJsonDocument::fromJson(json.toUtf8()).array();
    if (answers.isEmpty() || answers.size() > 64)
        return std::nullopt;

    static const QRegularExpression callPattern(QStringLiteral(R"(\Acall_[A-Za-z0-9_-]{1,251}\z)"));
    QuestionItems result;
    for (const auto &entry : answers) {
        const auto answer = entry.toObject();
        if (answer.value("answer").toString().trimmed().isEmpty())
            return std::nullopt;
        const auto parts = QJsonDocument::fromJson(answer.value("questionItemId").toString().toUtf8()).array();
        if (parts.size() != 3 || parts.at(0).toString() != "request_user_input_async")
            return std::nullopt;
        const auto call = parts.at(1).toString();
        const auto number = parts.at(2);
        const int index = number.toInt(-1);
        if (!callPattern.match(call).hasMatch() || !number.isDouble() || index < 0 || index >= 64
            || result.value(call).contains(index))
            return std::nullopt;
        result[call].insert(index);
    }
    return result;
}

std::optional<QuestionReplyReceipt> QuestionReplyReceipt::parse(const QString &text,
    const QString &threadID, const QString &turnID, const QString &clientID, const QDateTime &receivedAt)
{
    if (!isUUID(threadID) || !isUUID(turnID) || !isUUID(clientID) || !receivedAt.isValid())
        return std::nullopt;
    const auto items = parseQuestionItems(text);
    if (!items)
        return std::nullopt;
    return QuestionReplyReceipt{threadID, turnID, clientID, receivedAt, *items};
}

std::optional<QuestionReplyReceipt> QuestionReplyReceipt::parse(const QString &text,
    const QString &threadID, const QString &turnID, const QString &clientID, double receivedMilliseconds)
{
    // double(INT64_MAX) 向上舍入为 2^63，必须严格小于此边界再转整数。
    if (!std::isfinite(receivedMilliseconds) || receivedMilliseconds < double(std::numeric_limits<qint64>::min())
        || receivedMilliseconds >= double(std::numeric_limits<qint64>::max()))
        return std::nullopt;
    // Swift Date(timeIntervalSince1970: milliseconds / 1000) 在转换后以 2001 为零点。
    const auto reference = receivedMilliseconds / 1000.0 - 978307200.0;
    const auto timestamp = PreciseTimestamp::fromReferenceSeconds(reference);
    if (!timestamp) return std::nullopt;
    auto receipt = parse(text, threadID, turnID, clientID, timestamp->date);
    if (receipt && PreciseTimestamp{receipt->receivedAt}.referenceSeconds() != reference)
        receipt->preciseReceivedSeconds = reference;
    return receipt;
}

} // namespace codextop
