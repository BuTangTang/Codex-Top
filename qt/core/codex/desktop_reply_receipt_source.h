#pragma once

#include "question_reply_receipt.h"

#include <QDeadlineTimer>
#include <QJsonObject>
#include <QList>
#include <mutex>
#include <stop_token>

namespace codextop {

struct DesktopReceiptLimits {
    double timeout = 1.5; // seconds
    int maximumThreads = 16;
    int maximumFrameBytes = 64 * 1024 * 1024;
    int maximumTotalBytes = 96 * 1024 * 1024;
    int maximumFrames = 128;
    int maximumTurns = 512;
    int maximumItems = 16384;
    int maximumReceipts = 128;
};

namespace DesktopReceiptProtocol {
std::optional<QList<QuestionReplyReceipt>> receipts(const QJsonObject &state, const QString &threadID,
    const QDateTime &askedAt, const QDateTime &now, const DesktopReceiptLimits &limits,
    QDeadlineTimer deadline = QDeadlineTimer::Forever, std::stop_token cancellation = {});
}

// 在采集线程调用。一轮读取共用总时限，可取消，不会启动或取得桌面任务的所有权。
class DesktopReplyReceiptSource {
public:
    explicit DesktopReplyReceiptSource(const QString &root, DesktopReceiptLimits limits = {});

#ifdef Q_OS_WIN
    // 正式管道当前不能证明所属的数据根。显式提供的合成管道只允许用于对应的临时根。
    DesktopReplyReceiptSource(const QString &root, DesktopReceiptLimits limits, const QString &fixturePipe);
#endif
    QList<QuestionReplyReceipt> receipts(const QHash<QString, QDateTime> &threads, const QDateTime &now,
                                         std::stop_token cancellation = {});
private:
    QString root_;
    QString windowsPipe_;
    DesktopReceiptLimits limits_;
    std::mutex rotationMutex_;
    qsizetype nextThread_ = 0;
};

} // namespace codextop
