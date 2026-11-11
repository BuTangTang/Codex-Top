#pragma once
#include "models/models.h"
#include <QByteArray>
#include <QSet>
#include <memory>

namespace codextop {
struct QuestionReplyReceipt;

// 单线程持有这个读取器。压缩正文在独立串行队列解码，快照只取已完成的结果。
class CompressedRolloutReader {
  public:
    enum class Category { Reading, Ready, Unavailable, Limited };
    struct Result {
        TaskActivity activity;
        std::optional<QuotaSnapshot> quota;
        Category category = Category::Reading;
        qint64 bytes = 0;
    };
    struct LongLine {
        enum Kind { Ignore, Line, Gap } kind = Gap;
        QByteArray data;
    };
    /// 设置累计输出限额，可选缓存路径保存已完成的状态。
    explicit CompressedRolloutReader(qint64 maximumOutput = qint64(1) << 46, QString cachePath = {});
    /// 停止解码并回收队列所持有的文件资源。
    ~CompressedRolloutReader();
    /// 保留本轮关注的任务，为新解码腾出本轮启动名额。
    void beginCycle(const QSet<QString> &ids);
    /// 测试使用，等待当前解码结束；正式快照不阻塞等待。
    void waitForBackgroundRead();
    /// 普通记录恢复时清除该任务的压缩缓存和进行中的解码。
    void forget(const QString &id);
    /// 获取与当前文件身份匹配的结果，或开始/排队一次后台读取。
    Result read(const QString &id, const QString &path, const QDateTime &now);
    /// 返回完整结果中最早可与桌面证据匹配的提问时间。
    std::optional<QDateTime> awaitingReplySince(const QString &id) const;
    /// 使用已验证的回执投影等待状态，不重新打开普通记录。
    std::optional<TaskActivity> projectedActivity(const QString &id, const QList<QuestionReplyReceipt> &receipts,
                                                  const QDateTime &now) const;
    /// 从超长行的有限前缀提取状态字段，缺失关键字段时标记证据缺口。
    static LongLine summarizeLongLine(const QByteArray &prefix);

  private:
    struct Impl;
    std::unique_ptr<Impl> d;
};
} // namespace codextop
