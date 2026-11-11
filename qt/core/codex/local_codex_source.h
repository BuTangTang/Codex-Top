#pragma once
#include "models/models.h"
#include <QSet>
#include <memory>

namespace codextop {
class DesktopReplyReceiptSource;

// 从指定数据目录只读取得一轮快照。每个源串行更新自身的增量游标与标签缓存。
class LocalCodexSource {
  public:
    /// 创建专属数据源；可选压缩结果缓存属于应用自己的状态目录，回执源可注入用于隔离验证。
    explicit LocalCodexSource(QString root, QString compressedCachePath = {},
                              std::shared_ptr<DesktopReplyReceiptSource> receiptSource = {});
    /// 释放增量状态，并等待本源的后台解码安全结束。
    ~LocalCodexSource();
    /// 返回实际校验目录边界所用的规范化根路径。
    const QString &root() const;
    /// 使用非空 CODEX_HOME，否则返回当前系统用户的默认目录。
    static QString defaultRoot();
    /// 同步读取一轮；指定根可回查本轮开始时间，显式关注范围限制解压与诊断计数。
    SourceSnapshot snapshot(QDateTime now = QDateTime::currentDateTimeUtc(), const QSet<QString> &recoverTimingFor = {},
                            const std::optional<QSet<QString>> &monitoredRootIDs = std::nullopt);

  private:
    struct Impl;
    std::unique_ptr<Impl> d;
};
} // namespace codextop
