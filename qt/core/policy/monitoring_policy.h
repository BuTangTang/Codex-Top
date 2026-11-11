#pragma once

#include "models/task_roots.h"
#include "policy/monitor_preferences.h"

namespace codextop {

// 单次快照的根、全部后代以及优先级最高的活动来源；同级后代按输入顺序。
class TaskGraph {
public:
    explicit TaskGraph(const QList<CodexTask> &tasks);
    QHash<QString, QString> rootIDs;
    QList<CodexTask> roots;
    QHash<QString, QList<CodexTask>> children;
    QString rootID(const QString &id) const;
    CodexTask activitySource(const CodexTask &root) const;
    TaskActivity activity(const CodexTask &root) const;
    CodexTask navigationTarget(const CodexTask &root) const;

private:
    QHash<QString, CodexTask> activityChildren_;
};

namespace MonitoringPolicy {
QString rootID(const QString &id, const QList<CodexTask> &tasks);
QList<CodexTask> roots(const QList<CodexTask> &tasks);
QList<CodexTask> children(const QString &id, const QList<CodexTask> &tasks);
TaskActivity activity(const CodexTask &task, const QList<CodexTask> &tasks);
void reconcile(MonitorPreferences &preferences, const QList<CodexTask> &tasks, const QDateTime &now);
void reconcile(MonitorPreferences &preferences, const QList<CodexTask> &tasks, const TaskGraph &graph, const QDateTime &now);
void setAutoMonitor(bool enabled, MonitorPreferences &preferences, const QList<CodexTask> &tasks, const QDateTime &now);
void applySelection(const QSet<QString> &draft, const QSet<QString> &original, MonitorPreferences &preferences);
void selectVisible(const QSet<QString> &visible, QSet<QString> &selected);
void applyClaudeBaseline(MonitorPreferences &preferences, const QList<CodexTask> &claudeTasks);
}

} // namespace codextop
