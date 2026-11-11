#pragma once
#include "policy/monitor_status_summary.h"

namespace codextop {
/// 收起时左侧显示任务优先状态，右侧显示最多两个额度窗口的剩余百分比。
struct CompactMonitorSummary {
    CompactMonitorSummary(const MonitorStatusSummary &status, bool paused, const std::optional<QuotaSnapshot> &quota,
                          const QDateTime &now);
    QString leftText;
    TaskPhase leftPhase;
    QStringList quotaLines;
    bool isQuotaStale = false;
    bool operator==(const CompactMonitorSummary &) const = default;
};
} // namespace codextop
