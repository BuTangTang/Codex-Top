#include "policy/monitoring_policy.h"
#include <QtTest>
#include <QTimeZone>

using namespace codextop;
namespace mp = MonitoringPolicy;
using Phase = TaskPhase;
namespace {
using IDs = QSet<QString>;
const auto now = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
CodexTask makeTask(const QString &id, Phase phase = Phase::Idle, const QDateTime &created = now.addSecs(-100),
                   std::optional<QString> parent = {}) {
    CodexTask task;
    task.id = id;
    task.title = id;
    task.project = "Sample";
    task.createdAt = created;
    task.updatedAt = now;
    task.parentID = parent;
    task.rolloutPath = "/tmp/fixture.jsonl";
    task.activity.phase = phase;
    return task;
}
QSet<QString> ids(const QList<CodexTask> &tasks) {
    QSet<QString> result;
    for (const auto &task : tasks)
        result.insert(task.id);
    return result;
}
} // namespace
class CorePolicyTests : public QObject {
    Q_OBJECT
  private slots:
    void testFirstScanAndAutoMonitorDoNotFloodHistory() {
        MonitorPreferences p;
        auto old = makeTask("history", Phase::Completed), active = makeTask("active", Phase::Running);
        mp::reconcile(p, {old, active}, now);
        QCOMPARE(p.selectedIDs, IDs{"active"});
        auto fresh = makeTask("fresh", Phase::Completed, now.addSecs(1));
        mp::reconcile(p, {old, active, fresh}, now.addSecs(2));
        QCOMPARE(p.selectedIDs, IDs({"active", "fresh"}));
    }
    void testSameSecondAutoEnableAddsNewIDsButNotKnownTasksAndPreservesExclusions() {
        MonitorPreferences p;
        p.initialized = true;
        p.autoMonitor = false;
        auto old = makeTask("known", Phase::Completed, now);
        mp::setAutoMonitor(true, p, {old}, now.addMSecs(250));
        auto fresh = makeTask("fresh", Phase::Idle, now);
        mp::reconcile(p, {old, fresh}, now.addMSecs(400));
        QVERIFY(p.selectedIDs.isEmpty());
        fresh.activity.phase = Phase::Running;
        fresh.activity.startedAt = now.addMSecs(500);
        mp::reconcile(p, {old, fresh}, now.addSecs(1));
        QCOMPARE(p.selectedIDs, IDs{"fresh"});
        mp::applySelection({}, {"fresh"}, p);
        mp::reconcile(p, {old, fresh}, now.addSecs(2));
        QVERIFY(p.selectedIDs.isEmpty());
        QVERIFY(p.excludedIDs.contains("fresh"));
        mp::setAutoMonitor(false, p, {old, fresh}, now.addSecs(2));
        auto whileOff = makeTask("while-off", Phase::Running, now.addSecs(2));
        mp::reconcile(p, {old, fresh, whileOff}, now.addMSecs(2100));
        QVERIFY(p.selectedIDs.isEmpty());
        mp::setAutoMonitor(true, p, {old, fresh, whileOff}, now.addMSecs(2250));
        auto afterEnable = makeTask("after-enable", Phase::Waiting, now.addSecs(2));
        mp::reconcile(p, {old, fresh, whileOff, afterEnable}, now.addSecs(3));
        QCOMPARE(p.selectedIDs, IDs({"after-enable", "while-off"}));
    }
    void testFirstScanBoundaryAndRestartKeepHistoricalTasksOut() {
        MonitorPreferences p;
        auto old = makeTask("same-second-history", Phase::Completed, now),
             active = makeTask("active", Phase::Running);
        mp::reconcile(p, {old, active}, now.addMSecs(250));
        QCOMPARE(p.selectedIDs, IDs{"active"});
        p = MonitorPreferences::fromJson(
            QJsonDocument::fromJson(QJsonDocument(p.toJson()).toJson()).object());
        auto fresh = makeTask("fresh", Phase::Completed, now);
        mp::reconcile(p, {old, active, fresh}, now.addSecs(2));
        QCOMPARE(p.selectedIDs, IDs({"active", "fresh"}));
        QCOMPARE(p.autoBaselineIDs, std::optional(IDs{"same-second-history", "active"}));
    }
    void testLegacyPreferencesEstablishBoundaryBaselineWithoutLosingLaterCatchUp() {
        MonitorPreferences p;
        p.initialized = true;
        p.autoEnabledAt = now.addMSecs(250);
        p.selectedIDs = {"kept"};
        p.excludedIDs = {"excluded"};
        auto legacy = p.toJson();
        legacy.remove("autoBaselineIDs");
        p = MonitorPreferences::fromJson(legacy);
        QVERIFY(!p.autoBaselineIDs);
        mp::reconcile(p,
                      {makeTask("ambiguous-history", Phase::Completed, now),
                       makeTask("later", Phase::Completed, now.addSecs(1)),
                       makeTask("excluded", Phase::Running, now.addSecs(1))},
                      now.addSecs(2));
        QCOMPARE(p.selectedIDs, IDs({"kept", "later"}));
        QCOMPARE(p.autoBaselineIDs, std::optional(IDs{"ambiguous-history"}));
        QCOMPARE(p.excludedIDs, IDs{"excluded"});
    }
    void testManualExclusionWinsAndSelectionPreservesConcurrentAddition() {
        MonitorPreferences p;
        p.initialized = true;
        p.autoEnabledAt = now;
        p.selectedIDs = {"a", "new-arrival"};
        mp::applySelection({}, {"a"}, p);
        QCOMPARE(p.selectedIDs, IDs{"new-arrival"});
        mp::reconcile(p, {makeTask("a", Phase::Running, now)}, now);
        QVERIFY(!p.selectedIDs.contains("a"));
        mp::applySelection({"a"}, {}, p);
        QVERIFY(!p.excludedIDs.contains("a"));
    }
    void testAutoOffAndSelectAllOnlyAffectCurrentResults() {
        MonitorPreferences p;
        p.initialized = true;
        p.autoMonitor = false;
        mp::reconcile(p, {makeTask("new", Phase::Running, now)}, now);
        QVERIFY(p.selectedIDs.isEmpty());
        IDs selected{"outside"};
        mp::selectVisible({"a", "b"}, selected);
        QCOMPARE(selected, IDs({"outside", "a", "b"}));
        mp::selectVisible({"a", "b"}, selected);
        QCOMPARE(selected, IDs{"outside"});
    }
    void testChildIsFoldedUnderRootAndElevatesAttention() {
        QList<CodexTask> tasks{makeTask("parent", Phase::Completed),
                               makeTask("child", Phase::Waiting, now.addSecs(-100), "parent")};
        QCOMPARE(ids(mp::roots(tasks)), IDs{"parent"});
        QCOMPARE(mp::activity(tasks[0], tasks).phase, Phase::Waiting);
        MonitorPreferences p;
        mp::reconcile(p, tasks, now);
        QCOMPARE(p.selectedIDs, IDs{"parent"});
    }
    void testGraphHandlesGrandchildrenOrphansAndCycles() {
        auto child = [](const QString &id, const QString &parent) {
            return makeTask(id, Phase::Idle, now.addSecs(-100), parent);
        };
        TaskGraph graph({makeTask("a"), child("b", "a"), child("c", "b"), child("orphan", "missing"),
                         child("x", "y"), child("y", "x")});
        QCOMPARE(ids(graph.roots), IDs({"a", "orphan", "x"}));
        QCOMPARE(ids(graph.children.value("a")), IDs({"b", "c"}));
        QCOMPARE(graph.rootIDs.value("y"), QString("x"));
    }
};
QTEST_APPLESS_MAIN(CorePolicyTests)
#include "test_core_policy.moc"
