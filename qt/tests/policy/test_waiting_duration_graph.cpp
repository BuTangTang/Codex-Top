#include "policy_fixture.h"
using namespace policy_test;
class WaitingDurationGraphTests : public QObject {
    Q_OBJECT
private slots:
    void testChildAggregationRetainsTheChildStartAndWaitAnchor() {
        auto parent = task("parent", TaskPhase::Running);
        auto child = task("child", TaskPhase::Waiting, "parent");
        parent.title = "Parent";
        child.title = "Child";
        parent.project = child.project = "Sample";
        parent.rolloutPath = "/tmp/parent.jsonl";
        child.rolloutPath = "/tmp/child.jsonl";
        parent.activity = {};
        parent.activity.phase = TaskPhase::Running;
        parent.activity.startedAt = now;
        child.activity = {};
        child.activity.phase = TaskPhase::Waiting;
        child.activity.lastEventAt = now.addSecs(80);
        child.activity.startedAt = now.addSecs(20);
        child.activity.waitingStartedAt = now.addSecs(35);
        const auto aggregate = TaskGraph({parent, child}).activity(parent);
        QCOMPARE(aggregate.waitingElapsedSeconds(), 15);
        QCOMPARE(aggregate.startedAt, child.activity.startedAt);
        QCOMPARE(aggregate.waitingStartedAt, child.activity.waitingStartedAt);
        QVERIFY(aggregate.detail.startsWith(QStringLiteral("子任务")));
    }
};
QTEST_APPLESS_MAIN(WaitingDurationGraphTests)
#include "test_waiting_duration_graph.moc"
