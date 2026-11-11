#pragma once
#include "usage/usage_day_boundary.h"
#include <QHash>
#include <QMutex>
#include <QStringList>

namespace codextop {
/// 输入已经包含缓存命中数，输出已经包含推理数。
struct CodexTokens {
    qint64 input = 0, cached = 0, output = 0, reasoning = 0;
    qint64 total() const { return input + output; }
    CodexTokens &operator+=(const CodexTokens &other) {
        input += other.input;
        cached += other.cached;
        output += other.output;
        reasoning += other.reasoning;
        return *this;
    }
    bool operator==(const CodexTokens &) const = default;
};
using CodexUsageSummary = TokenUsageSummary<CodexTokens>;
class CodexUsageCounter {
  public:
    /// 普通记录列表由调用方提供，每个文件只读到最后一条完整行。
    CodexUsageSummary summary(const QStringList &paths, const QDateTime &now = QDateTime::currentDateTimeUtc(),
                              const UsageDayBoundary &boundary = UsageDayBoundary::localNoon());

  private:
    struct FileState {
        qint64 offset = 0;
        CodexTokens last;
        QHash<QDateTime, CodexTokens> buckets;
    };
    QMutex mutex;
    QHash<QString, FileState> files;
};
} // namespace codextop
