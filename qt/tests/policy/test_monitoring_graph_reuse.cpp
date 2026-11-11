#include "policy_fixture.h"
using namespace policy_test;
namespace {
CodexTask observed(const QString &id, TaskPhase phase, const QDateTime &last, std::optional<QString> parent = std::nullopt) {
    auto t = task(id, phase, parent);
    t.updatedAt = last;
    t.rolloutPath = "/synthetic/rollout";
    t.activity = {};
    t.activity.phase = phase;
    t.activity.lastEventAt = last;
    return t;
}
}
class MonitoringGraphReuseTests : public QObject {
    Q_OBJECT
private slots:
    void testUnchangedGraphStillRetiresAtLaterTimeBoundary() {
        const QList tasks = {observed("root", TaskPhase::Completed, now.addSecs(-7 * 86400 + 1))};
        const TaskGraph graph(tasks);
        MonitorPreferences p;
        p.initialized = true;
        p.autoMonitor = false;
        p.autoBaselineIDs = p.selectedIDs = {"root"};
        p.finishedRetentionDays = 7;
        MonitoringPolicy::reconcile(p, tasks, graph, now);
        QCOMPARE(p.selectedIDs, QSet<QString>{"root"});
        MonitoringPolicy::reconcile(p, tasks, graph, now.addSecs(1));
        QVERIFY(p.selectedIDs.isEmpty());
        QCOMPARE(p.automaticallyRemovedIDs, QSet<QString>{"root"});
    }
    void testOriginalEntryAndPrebuiltGraphPreserveDiscoveryAndLegacyPreferences() {
        const QList tasks = {observed("root", TaskPhase::Completed, now), observed("child", TaskPhase::Waiting, now, "root"),
            observed("excluded", TaskPhase::Running, now)};
        const TaskGraph graph(tasks);
        MonitorPreferences initial;
        initial.excludedIDs = {"excluded"};
        auto legacy = initial;
        legacy.initialized = true;
        legacy.autoEnabledAt = now.addSecs(-10);
        legacy.autoBaselineIDs.reset();
        for (const auto &starting : {initial, legacy}) {
            auto original = starting, reused = starting;
            MonitoringPolicy::reconcile(original, tasks, now);
            MonitoringPolicy::reconcile(reused, tasks, graph, now);
            QCOMPARE(reused, original);
            QCOMPARE(reused.selectedIDs, QSet<QString>{"root"});
            QCOMPARE(reused.excludedIDs, QSet<QString>{"excluded"});
            QVERIFY(reused.autoBaselineIDs);
        }
    }
};
QTEST_APPLESS_MAIN(MonitoringGraphReuseTests)
#include "test_monitoring_graph_reuse.moc"
