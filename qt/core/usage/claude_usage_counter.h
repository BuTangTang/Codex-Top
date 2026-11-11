#pragma once
#include "usage/usage_day_boundary.h"
#include <QHash>
#include <QMutex>
#include <QStringList>

namespace codextop {
struct ClaudeTokens {
    qint64 input = 0, output = 0, cacheRead = 0;
    qint64 total() const { return input + output + cacheRead; }
    ClaudeTokens &operator+=(const ClaudeTokens &other) {
        input += other.input;
        output += other.output;
        cacheRead += other.cacheRead;
        return *this;
    }
    bool operator==(const ClaudeTokens &) const = default;
};
using ClaudeUsageSummary = TokenUsageSummary<ClaudeTokens>;
/// 只缓存消息编号、用量和日期，不存正文。
class ClaudeUsageCounter {
  public:
    explicit ClaudeUsageCounter(const QString &root);
    ClaudeUsageSummary summary(const QDateTime &now = QDateTime::currentDateTimeUtc(),
                               const UsageDayBoundary &boundary = UsageDayBoundary::localNoon());

  private:
    struct Entry {
        QDateTime day;
        ClaudeTokens tokens;
    };
    struct FileState {
        qint64 offset = 0;
        QHash<QString, Entry> entries;
        QHash<QDateTime, ClaudeTokens> unnamed;
    };
    QMutex mutex;
    QString root;
    QHash<QString, FileState> files;
    QStringList transcripts(const QDateTime &modifiedSince) const;
};
} // namespace codextop
