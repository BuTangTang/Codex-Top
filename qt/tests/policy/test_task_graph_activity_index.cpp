#include "policy_fixture.h"
using namespace policy_test;

class TaskGraphActivityIndexTests : public QObject {
    Q_OBJECT
private slots:
    void testAllRootAndChildPhasesPreserveOriginalSelectionInBothOrders() {
        for (auto rootPhase : phases) {
            const auto root = task("root", rootPhase);
            for (auto firstPhase : phases) {
                const auto first = task("first", firstPhase, root.id);
                for (auto secondPhase : phases) {
                    const auto second = task("second", secondPhase, root.id);
                    for (const auto &ordered : {QList{first, second}, QList{second, first}})
                        compareSelection(TaskGraph(QList{root} + ordered), root, ordered);
                }
            }
        }
    }
    void testEveryPassedRootPhaseIsComparedInsteadOfStoredRootPhase() {
        for (auto storedPhase : phases) {
            const auto stored = task("root", storedPhase);
            for (auto childPhase : phases) {
                const auto child = task("child", childPhase, stored.id);
                const TaskGraph graph({stored, child});
                for (auto passedPhase : phases) {
                    auto passed = task("root", passedPhase);
                    passed.title = "Updated caller value";
                    passed.activity.detail = "caller activity";
                    passed.activity.startedAt = at(1800000100);
                    compareSelection(graph, passed, {child});
                    if (phasePriority(childPhase) >= phasePriority(passedPhase) || (!isActive(childPhase) && childPhase != TaskPhase::Failed))
                        QCOMPARE(graph.activitySource(passed), passed);
                }
            }
        }
    }
    void testEmptyGraphsAndRootsWithoutChildrenReturnCallerValue() {
        for (auto phase : phases) {
            const auto root = task("root", phase);
            for (const auto &graph : {TaskGraph({}), TaskGraph({root})}) {
                QCOMPARE(graph.activitySource(root), root);
                QCOMPARE(graph.activity(root), root.activity);
                QCOMPARE(graph.navigationTarget(root), root);
            }
            const auto other = task("other", TaskPhase::Completed);
            const auto waiting = task("waiting", TaskPhase::Waiting, other.id);
            QCOMPARE(TaskGraph({other, waiting}).activitySource(root), root);
        }
    }
    void testFirstPendingDescendantSuppliesTimingDetailAndNavigation() {
        const auto root = task("root", TaskPhase::Completed);
        const auto branch = task("branch", TaskPhase::Running, root.id);
        auto direct = task("direct", TaskPhase::Waiting, root.id);
        auto descendant = task("descendant", TaskPhase::Waiting, branch.id);
        direct.activity.waitingStartedAt = at(1800000020);
        descendant.activity.waitingStartedAt = at(1800000030);
        for (const auto &ordered : {QList{descendant, root, branch, direct}, QList{direct, root, branch, descendant}}) {
            const TaskGraph graph(ordered);
            const auto expected = ordered.first();
            QCOMPARE(graph.activitySource(root), expected);
            QCOMPARE(graph.navigationTarget(root), expected);
            QCOMPARE(graph.activity(root).waitingStartedAt, expected.activity.waitingStartedAt);
            QCOMPARE(graph.activity(root).startedAt, expected.activity.startedAt);
            QCOMPARE(graph.activity(root).detail, QStringLiteral("子任务 · ") + expected.activity.detail);
            QCOMPARE(graph.rootIDs.value(descendant.id), root.id);
            compareSelection(graph, root, graph.children.value(root.id));
        }
    }
    void testRebuildingGraphTracksCompletionResumptionAndReparenting() {
        const auto root = task("root", TaskPhase::Completed);
        const auto other = task("other", TaskPhase::Completed);
        auto first = task("first", TaskPhase::Waiting, root.id);
        auto second = task("second", TaskPhase::Running, root.id);
        const TaskGraph original({root, other, first, second});
        QCOMPARE(original.navigationTarget(root), first);
        first.activity.phase = TaskPhase::Completed;
        second.activity.phase = TaskPhase::Failed;
        const TaskGraph failed({root, other, first, second});
        QCOMPARE(failed.activitySource(root), second);
        QCOMPARE(failed.navigationTarget(root), root);
        compareSelection(failed, root, {first, second});
        second.activity.phase = TaskPhase::Stopped;
        QCOMPARE(TaskGraph({root, other, first, second}).activitySource(root), root);
        first.activity.phase = TaskPhase::Waiting;
        first.parentID = other.id;
        const TaskGraph resumed({root, other, first, second});
        QCOMPARE(resumed.activitySource(root), root);
        QCOMPARE(resumed.navigationTarget(other), first);
        QCOMPARE(resumed.children.value(root.id), QList{second});
        QCOMPARE(resumed.children.value(other.id), QList{first});
        QCOMPARE(original.navigationTarget(root).activity.phase, TaskPhase::Waiting);
        QCOMPARE(original.navigationTarget(root).parentID, root.id);
        compareSelection(resumed, root, {second});
        compareSelection(resumed, other, {first});
    }
    void testMultipleRootsOrphansAndCyclesKeepTheirOwnActivitySource() {
        const auto root = task("root", TaskPhase::Completed);
        const auto child = task("child", TaskPhase::Running, root.id);
        const auto orphan = task("orphan", TaskPhase::Unknown, "missing");
        const auto orphanChild = task("orphan-child", TaskPhase::Failed, orphan.id);
        const auto cycleRoot = task("cycle-a", TaskPhase::Completed, "cycle-b");
        const auto cycleChild = task("cycle-b", TaskPhase::Waiting, cycleRoot.id);
        const TaskGraph graph({child, orphanChild, cycleChild, root, orphan, cycleRoot});
        QCOMPARE(ids(graph.roots), (QSet{root.id, orphan.id, cycleRoot.id}));
        QCOMPARE(graph.activitySource(root), child);
        QCOMPARE(graph.activitySource(orphan), orphanChild);
        QCOMPARE(graph.navigationTarget(cycleRoot), cycleChild);
        for (const auto &queried : graph.roots + QList{child, orphanChild, cycleChild})
            compareSelection(graph, queried, graph.children.value(queried.id));
    }
};
QTEST_APPLESS_MAIN(TaskGraphActivityIndexTests)
#include "test_task_graph_activity_index.moc"
