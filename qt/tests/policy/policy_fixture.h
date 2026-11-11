#pragma once
#include "policy/monitoring_policy.h"
#include <QtTest>
#include <QTimeZone>

namespace policy_test {
using namespace codextop;
inline QDateTime at(qint64 seconds) {
    return QDateTime::fromSecsSinceEpoch(seconds, QTimeZone::UTC);
}
inline const auto now = at(1800000000);
inline constexpr TaskPhase phases[] = {TaskPhase::Running, TaskPhase::Waiting, TaskPhase::Completed,
    TaskPhase::Failed, TaskPhase::Stopped, TaskPhase::Idle, TaskPhase::Unknown};
inline CodexTask task(const QString &id, TaskPhase phase, std::optional<QString> parent = std::nullopt) {
    CodexTask t;
    t.id = id;
    t.title = id;
    t.project = "Synthetic";
    t.createdAt = t.updatedAt = now;
    t.parentID = std::move(parent);
    t.rolloutPath = "/synthetic/" + id + ".jsonl";
    t.activity.phase = phase;
    t.activity.detail = "activity " + id;
    t.activity.lastEventAt = t.activity.waitingStartedAt = now;
    t.activity.startedAt = now.addSecs(-10);
    t.activity.turnID = "turn-" + id;
    return t;
}
inline QSet<QString> ids(const QList<CodexTask> &tasks) {
    QSet<QString> result;
    for (const auto &t : tasks)
        result.insert(t.id);
    return result;
}
// 此对照规则只从子任务顺序扫描，不走活动索引。
inline void compareSelection(const TaskGraph &graph, const CodexTask &root, const QList<CodexTask> &children) {
    auto source = root;
    for (const auto &child : children) {
        const auto phase = child.activity.phase;
        if ((isActive(phase) || phase == TaskPhase::Failed) && phasePriority(phase) < phasePriority(source.activity.phase))
            source = child;
    }
    QCOMPARE(graph.activitySource(root), source);
    auto aggregate = source.activity;
    if (source.id.normalized(QString::NormalizationForm_C) != root.id.normalized(QString::NormalizationForm_C))
        aggregate.detail.prepend(QStringLiteral("子任务 · "));
    QCOMPARE(graph.activity(root), aggregate);
    QCOMPARE(graph.navigationTarget(root), source.activity.phase == TaskPhase::Waiting ? source : root);
}
}
