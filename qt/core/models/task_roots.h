#pragma once
#include "models/models.h"
#include <QHash>

namespace codextop {
// 每个任务归到最高层祖先；孤儿自成根，循环取环内最小编号。
QHash<QString, QString> resolveRootIDs(const QList<CodexTask> &tasks);
} // namespace codextop
