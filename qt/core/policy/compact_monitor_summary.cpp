#include "policy/compact_monitor_summary.h"
#include <algorithm>

namespace codextop {
namespace {
QString period(qint64 minutes) {
    if (minutes == 10080)
        return QStringLiteral("周");
    return minutes % 60 == 0 ? QString::number(minutes / 60) + 'h' : QString::number(minutes) + 'm';
}
} // namespace
CompactMonitorSummary::CompactMonitorSummary(const MonitorStatusSummary &status, bool paused,
                                             const std::optional<QuotaSnapshot> &quota, const QDateTime &now) {
    if (status.attention() > 0) {
        leftText = QString::number(status.attention()) + QStringLiteral(" 待处理");
        leftPhase = status.phase;
    } else if (paused) {
        leftText = QStringLiteral("已暂停");
        leftPhase = TaskPhase::Idle;
    } else if (status.running > 0) {
        leftText = QString::number(status.running) + QStringLiteral(" 运行中");
        leftPhase = TaskPhase::Running;
    } else {
        leftText = status.total == 0 ? QStringLiteral("无任务") : phaseLabel(status.phase);
        leftPhase = status.phase;
    }
    if (!quota || quota->windows.isEmpty()) {
        quotaLines.append(QStringLiteral("额度暂无数据"));
        return;
    }
    auto reset = [&](const QuotaWindow &window) { return window.resetsAt && *window.resetsAt <= now; };
    isQuotaStale =
        quota->observedAt.msecsTo(now) > 300000 || std::any_of(quota->windows.cbegin(), quota->windows.cend(), reset);
    auto windows = quota->windows;
    std::stable_sort(windows.begin(), windows.end(),
                     [](const auto &a, const auto &b) { return a.minutes < b.minutes; });
    for (const auto &window : std::as_const(windows)) {
        const auto balance =
            reset(window) ? QStringLiteral("待更新") : QString::number(window.remainingPercent()) + '%';
        quotaLines.append(period(window.minutes) + ' ' + balance);
        if (quotaLines.size() == 2)
            break;
    }
}
} // namespace codextop
