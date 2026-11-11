#include "policy/monitor_status_summary.h"

namespace codextop {
MonitorStatusSummary::MonitorStatusSummary(const QList<TaskPhase> &phases)
    : total(phases.size()), running(phases.count(TaskPhase::Running)), waiting(phases.count(TaskPhase::Waiting)),
      failed(phases.count(TaskPhase::Failed)) {
    if (failed > 0)
        phase = TaskPhase::Failed;
    else if (waiting > 0)
        phase = TaskPhase::Waiting;
    else if (running > 0)
        phase = TaskPhase::Running;
    else if (phases.contains(TaskPhase::Unknown))
        phase = TaskPhase::Unknown;
    else if (phases.isEmpty() || phases.contains(TaskPhase::Idle))
        phase = TaskPhase::Idle;
    else if (phases.count(TaskPhase::Completed) == total)
        phase = TaskPhase::Completed;
    else
        phase = TaskPhase::Stopped;
}
} // namespace codextop
