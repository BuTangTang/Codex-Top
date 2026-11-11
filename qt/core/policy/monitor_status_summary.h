#pragma once
#include "models/models.h"

namespace codextop {
/// 收起面板时同时提供运行和待处理数量。
struct MonitorStatusSummary {
    explicit MonitorStatusSummary(const QList<TaskPhase> &phases);
    qsizetype total, running, waiting, failed;
    TaskPhase phase;
    qsizetype attention() const { return waiting + failed; }
    bool operator==(const MonitorStatusSummary &) const = default;
};
} // namespace codextop
