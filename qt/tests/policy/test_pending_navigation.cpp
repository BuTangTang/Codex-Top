#include "policy/monitoring_policy.h"
#include <QTest>
using namespace codextop;
using Phase = TaskPhase;
class PendingNavigationTests : public QObject {
    Q_OBJECT
    static CodexTask task(const QString &id, Phase phase, std::optional<QString> parent = {}) {
        CodexTask t;
        t.id = id;
        t.title = "Synthetic task";
        t.project = "Fixture";
        t.parentID = std::move(parent);
        t.createdAt = t.updatedAt = QDateTime::fromSecsSinceEpoch(-62135769600LL, QTimeZone::UTC);
        t.rolloutPath = "/tmp/synthetic-rollout.jsonl";
        t.activity.phase = phase;
        return t;
    }
    const QList<Phase> all{Phase::Running, Phase::Waiting, Phase::Completed, Phase::Failed,
                           Phase::Stopped, Phase::Idle,    Phase::Unknown};
  private slots:
    void testPendingDescendantOpensItsOwnTaskInsteadOfCompletedRoot() {
        const auto root = task("00000000-0000-0000-0000-000000000001", Phase::Completed);
        const auto child = task("00000000-0000-0000-0000-000000000002", Phase::Running, root.id);
        const auto pending = task("00000000-0000-0000-0000-000000000003", Phase::Waiting, child.id);
        const TaskGraph graph({root, child, pending});
        QCOMPARE(graph.activity(root).phase, Phase::Waiting);
        QCOMPARE(graph.navigationTarget(root).id, pending.id);
        const auto link = graph.navigationTarget(root).deepLink();
        QVERIFY(link);
        QCOMPARE(link->toString(), "codex://threads/" + pending.id);
    }
    void testEqualPriorityUsesSameSourceForStatusTimingAndNavigation() {
        const auto root = task("root", Phase::Running);
        auto first = task("first", Phase::Waiting, root.id), second = task("second", Phase::Waiting, root.id);
        first.activity.waitingStartedAt = QDateTime::fromSecsSinceEpoch(1800000010, QTimeZone::UTC);
        second.activity.waitingStartedAt = QDateTime::fromSecsSinceEpoch(1800000020, QTimeZone::UTC);
        for (auto tasks : {QList{root, first, second}, QList{root, second, first}}) {
            TaskGraph graph(tasks);
            QCOMPARE(graph.activity(root).waitingStartedAt, graph.navigationTarget(root).activity.waitingStartedAt);
            QCOMPARE(graph.navigationTarget(root).id, tasks[1].id);
        }
    }
    void testRootQuestionKeepsRootDestinationWhenChildAlsoWaits() {
        const auto root = task("root", Phase::Waiting), child = task("child", Phase::Waiting, root.id);
        TaskGraph graph({root, child});
        QCOMPARE(graph.navigationTarget(root).id, root.id);
        QCOMPARE(graph.activitySource(root).id, root.id);
    }
    void testResolvedChildAndNonPendingStatesReturnToRootDestination() {
        const auto root = task("root", Phase::Completed);
        auto child = task("child", Phase::Waiting, root.id);
        QCOMPARE(TaskGraph({root, child}).navigationTarget(root).id, child.id);
        for (auto phase : all) {
            if (phase == Phase::Waiting)
                continue;
            child.activity.phase = phase;
            QCOMPARE(TaskGraph({root, child}).navigationTarget(root).id, root.id);
        }
    }
    void testInactiveAndUnknownChildrenNeverReplaceRootActivity() {
        for (auto phase : all) {
            const auto root = task("root", phase);
            QList<CodexTask> tasks{root};
            for (auto child : {Phase::Unknown, Phase::Idle, Phase::Completed, Phase::Stopped})
                tasks.append(task("child-" + QString::number(tasks.size() - 1), child, root.id));
            TaskGraph graph(tasks);
            QCOMPARE(graph.activitySource(root), root);
            QCOMPARE(graph.activity(root), root.activity);
        }
    }
    void testEveryEligibleTieKeepsRootOrFirstChildAndRespectsPassedRoot() {
        for (auto phase : {Phase::Running, Phase::Waiting, Phase::Failed}) {
            const auto root = task("root", phase), first = task("first", phase, root.id),
                       second = task("second", phase, root.id);
            QCOMPARE(TaskGraph({root, first, second}).activitySource(root), root);
            const auto completed = task("root", Phase::Completed);
            for (auto children : {QList{first, second}, QList{second, first}}) {
                TaskGraph graph(QList{completed} + children);
                QCOMPARE(graph.activitySource(completed), children[0]);
                QCOMPARE(graph.activitySource(root), root);
            }
        }
    }
};
QTEST_APPLESS_MAIN(PendingNavigationTests)
#include "test_pending_navigation.moc"
