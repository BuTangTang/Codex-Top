#pragma once
#include "models/models.h"
#include <QHash>

namespace codextop {
// Swift String 用 Unicode 规范等价匹配编号；任务原始拼写留给展示和文件查询。
inline QString taskIDKey(const QString &id) { return id.normalized(QString::NormalizationForm_C); }
// 每个任务归到最高层祖先；孤儿自成根，循环取环内最小编号。
QHash<QString, QString> resolveRootIDs(const QList<CodexTask> &tasks);
} // namespace codextop
