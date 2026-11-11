#pragma once

#include <QDateTime>
#include <QHash>
#include <QSet>
#include <QString>
#include <optional>

namespace codextop {

using QuestionItems = QHash<QString, QSet<int>>;

// 只保留桌面已接收回复的关联字段，正文和答案不进入归约器或日志。
struct QuestionReplyReceipt {
    QString threadID;
    QString turnID;
    QString clientID;
    QDateTime receivedAt;
    QuestionItems questionItems;
    std::optional<double> preciseReceivedSeconds; // JSON 的小数毫秒，按 Swift Date 的 2001 参考点保存
    double receivedReferenceSeconds() const;

    bool operator==(const QuestionReplyReceipt &) const = default;
    static std::optional<QuestionItems> parseQuestionItems(const QString &text);
    static std::optional<QuestionReplyReceipt> parse(const QString &text, const QString &threadID,
        const QString &turnID, const QString &clientID, const QDateTime &receivedAt);
    // 桌面接收时间以 JSON 数字毫秒提供，先验证范围再转换为 QDateTime。
    static std::optional<QuestionReplyReceipt> parse(const QString &text, const QString &threadID,
        const QString &turnID, const QString &clientID, double receivedMilliseconds);
    static bool isUUID(const QString &text);
};

} // namespace codextop
