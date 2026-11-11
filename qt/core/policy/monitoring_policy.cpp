#include "policy/monitoring_policy.h"
#include <QTimeZone>
#include <algorithm>
#include <cmath>

namespace codextop {

TaskGraph::TaskGraph(const QList<CodexTask> &tasks) : rootIDs(resolveRootIDs(tasks)) {
    for (const auto &task : tasks) {
        const QString id = taskIDKey(task.id);
        const QString root = rootIDs.value(id, id);
        if (root == id) {
            roots.append(task);
            continue;
        }
        children[root].append(task);
        const auto phase = task.activity.phase;
        if (!isActive(phase) && phase != TaskPhase::Failed)
            continue;
        const auto source = activityChildren_.constFind(root);
        if (source == activityChildren_.cend() || phasePriority(phase) < phasePriority(source->activity.phase))
            activityChildren_.insert(root, task);
    }
}

QString TaskGraph::rootID(const QString &id) const {
    const auto key = taskIDKey(id);
    return rootIDs.value(key, key);
}

CodexTask TaskGraph::activitySource(const CodexTask &root) const {
    const auto child = activityChildren_.constFind(taskIDKey(root.id));
    if (child != activityChildren_.cend() && phasePriority(child->activity.phase) < phasePriority(root.activity.phase))
        return *child;
    return root;
}

TaskActivity TaskGraph::activity(const CodexTask &root) const {
    const auto source = activitySource(root);
    if (taskIDKey(source.id) == taskIDKey(root.id))
        return root.activity;
    auto result = source.activity;
    result.detail.prepend(QStringLiteral("子任务 · "));
    return result;
}

CodexTask TaskGraph::navigationTarget(const CodexTask &root) const {
    const auto source = activitySource(root);
    return source.activity.phase == TaskPhase::Waiting ? source : root;
}

namespace MonitoringPolicy {
namespace {
QSet<QString> taskIDs(const QList<CodexTask> &tasks) {
    QSet<QString> result;
    for (const auto &task : tasks)
        result.insert(taskIDKey(task.id));
    return result;
}

bool contains(const std::optional<QSet<QString>> &set, const QString &id) {
    return set && set->contains(id);
}

void selectIfAllowed(MonitorPreferences &p, const QString &id) {
    if (!p.excludedIDs.contains(id))
        p.selectedIDs.insert(id);
}

// 原生库用 epoch 0 表示缺失的数据库时间。每一位成员都必须有可用的活动或更新时间。
std::optional<double> latestActivity(const CodexTask &task) {
    if (!task.updatedAt.isValid() || (task.activity.lastEventAt && !task.activity.lastEventAt->isValid()))
        return std::nullopt;
    auto latest = PreciseTimestamp{task.updatedAt}.referenceSeconds();
    if (const auto event = task.activity.lastEventTimestamp())
        latest = std::max(latest, event->referenceSeconds());
    static const double epoch = PreciseTimestamp{QDateTime::fromMSecsSinceEpoch(0, QTimeZone::UTC)}.referenceSeconds();
    return latest > epoch ? std::optional(latest) : std::nullopt;
}

void applyRetention(MonitorPreferences &p, const TaskGraph &graph, const QDateTime &now) {
    auto retired = p.automaticallyRemovedIDs.value_or(QSet<QString>{}) - p.excludedIDs;
    const int days = p.resolvedFinishedRetentionDays();
    if (days == 0) {
        p.selectedIDs.unite(retired);
        p.automaticallyRemovedIDs = QSet<QString>{};
        return;
    }
    const double cutoff = PreciseTimestamp{now}.referenceSeconds() - days * 86400.;
    for (const auto &root : graph.roots) {
        const auto id = taskIDKey(root.id);
        const bool wasRetired = retired.contains(id);
        if (!p.selectedIDs.contains(id) && !wasRetired)
            continue;
        const auto phase = graph.activity(root).phase;
        if (wasRetired && (isActive(phase) || phase == TaskPhase::Failed)) {
            retired.remove(id);
            selectIfAllowed(p, id);
            continue;
        }
        auto latest = latestActivity(root);
        bool allFinished = isFinished(root.activity.phase);
        const auto descendants = graph.children.value(id);
        for (const auto &child : descendants) {
            const auto childDate = latestActivity(child);
            if (!latest || !childDate) {
                latest.reset();
                break;
            }
            latest = std::max(*latest, *childDate);
            allFinished &= isFinished(child.activity.phase);
        }
        if (!latest)
            continue;
        if (wasRetired && isFinished(phase) && *latest > cutoff) {
            retired.remove(id);
            selectIfAllowed(p, id);
        } else if (!wasRetired && allFinished && *latest <= cutoff && !contains(p.retentionProtectedIDs, id)) {
            p.selectedIDs.remove(id);
            retired.insert(id);
        }
    }
    p.automaticallyRemovedIDs = retired;
}
} // namespace

QString rootID(const QString &id, const QList<CodexTask> &tasks) {
    return TaskGraph(tasks).rootID(id);
}
QList<CodexTask> roots(const QList<CodexTask> &tasks) {
    return TaskGraph(tasks).roots;
}
QList<CodexTask> children(const QString &id, const QList<CodexTask> &tasks) {
    return TaskGraph(tasks).children.value(taskIDKey(id));
}
TaskActivity activity(const CodexTask &task, const QList<CodexTask> &tasks) {
    return TaskGraph(tasks).activity(task);
}

void reconcile(MonitorPreferences &p, const QList<CodexTask> &tasks, const QDateTime &now) {
    reconcile(p, tasks, TaskGraph(tasks), now);
}

void reconcile(MonitorPreferences &p, const QList<CodexTask> &tasks, const TaskGraph &graph, const QDateTime &now) {
    if (!p.initialized) {
        p.autoEnabledAt = now;
        p.autoEnabledSubmillisecondNanoseconds = 0;
        p.autoBaselineIDs = taskIDs(tasks);
        for (const auto &task : tasks) {
            if (isActive(task.activity.phase))
                selectIfAllowed(p, graph.rootID(task.id));
        }
        p.initialized = true;
    }
    const double enabled = PreciseTimestamp{p.autoEnabledAt, p.autoEnabledSubmillisecondNanoseconds}.referenceSeconds();
    if (!p.autoBaselineIDs) {
        p.autoBaselineIDs.emplace();
        for (const auto &task : tasks) {
            if (task.createdAt.isValid() && PreciseTimestamp{task.createdAt}.referenceSeconds() < enabled)
                p.autoBaselineIDs->insert(taskIDKey(task.id));
        }
    }
    if (p.autoMonitor) {
        // 数据库的 creation 为整数秒。同秒内按启用时已存在的编号区别新旧任务。
        const double boundary = std::floor(enabled);
        for (const auto &task : tasks) {
            const auto phase = task.activity.phase;
            const QString root = graph.rootID(task.id);
            if (isActive(phase)) {
                selectIfAllowed(p, root);
            } else if (task.createdAt.isValid() && PreciseTimestamp{task.createdAt}.referenceSeconds() >= boundary
                       && !contains(p.autoBaselineIDs, taskIDKey(task.id))
                       && (task.activity.startedAt || isFinished(phase) || phase == TaskPhase::Failed)
                       && !contains(p.automaticallyRemovedIDs, root)) {
                selectIfAllowed(p, root);
            }
        }
    }
    applyRetention(p, graph, now);
    for (const auto &root : graph.roots) {
        const QString id = taskIDKey(root.id);
        if (!root.activity.isTeamChatImport || !p.selectedIDs.contains(id) || contains(p.retentionProtectedIDs, id))
            continue;
        const auto descendants = graph.children.value(id);
        if (std::all_of(descendants.cbegin(), descendants.cend(), [](const CodexTask &child) { return child.activity.isTeamChatImport; }))
            p.selectedIDs.remove(id);
    }
}

void setAutoMonitor(bool enabled, MonitorPreferences &p, const QList<CodexTask> &tasks, const QDateTime &now) {
    p.autoMonitor = enabled;
    if (enabled) {
        p.autoEnabledAt = now;
        p.autoEnabledSubmillisecondNanoseconds = 0;
        p.autoBaselineIDs = taskIDs(tasks);
    }
}
void applySelection(const QSet<QString> &draft, const QSet<QString> &original, MonitorPreferences &p) {
    const auto removed = original - draft;
    const auto added = draft - original;
    p.selectedIDs.subtract(removed).unite(added);
    p.excludedIDs.unite(removed).subtract(added);
    if (!p.retentionProtectedIDs)
        p.retentionProtectedIDs.emplace();
    p.retentionProtectedIDs->unite(added).subtract(removed);
    if (p.automaticallyRemovedIDs)
        p.automaticallyRemovedIDs->subtract(added | removed);
}
void selectVisible(const QSet<QString> &visible, QSet<QString> &selected) {
    if (selected.contains(visible))
        selected.subtract(visible);
    else
        selected.unite(visible);
}

void applyClaudeBaseline(MonitorPreferences &p, const QList<CodexTask> &claudeTasks) {
    if (p.claudeBaselineApplied.value_or(false) || claudeTasks.isEmpty())
        return;
    p.claudeBaselineApplied = true;
    if (!p.initialized)
        return;
    if (!p.autoBaselineIDs)
        p.autoBaselineIDs.emplace();
    p.autoBaselineIDs->unite(taskIDs(claudeTasks));
    for (const auto &task : claudeTasks) {
        if (isActive(task.activity.phase))
            selectIfAllowed(p, taskIDKey(task.id));
    }
}

} // namespace MonitoringPolicy
} // namespace codextop
