#include "policy_fixture.h"
#include <QJsonDocument>
using namespace policy_test;
using enum TaskPhase;
namespace {
CodexTask aged(const QString &id, TaskPhase phase, double daysAgo, std::optional<QString> parent = std::nullopt) {
    CodexTask t;
    t.id = t.title = id;
    t.project = "Synthetic";
    t.createdAt = now.addSecs(-100 * 86400);
    t.updatedAt = now.addMSecs(-qRound64(daysAgo * 86400000.));
    t.parentID = std::move(parent);
    t.rolloutPath = "/synthetic/rollout";
    t.activity.phase = phase;
    t.activity.lastEventAt = t.updatedAt;
    return t;
}
MonitorPreferences preferences(const QSet<QString> &selected) {
    MonitorPreferences p;
    p.initialized = true;
    p.autoMonitor = false;
    p.selectedIDs = selected;
    p.finishedRetentionDays = 7;
    return p;
}
MonitorPreferences roundTrip(const MonitorPreferences &p) {
    return MonitorPreferences::fromJson(QJsonDocument::fromJson(QJsonDocument(p.toJson()).toJson()).object());
}
}
class FinishedRetentionTests : public QObject {
    Q_OBJECT
private slots:
    void testOnlyOldTerminalConversationsExpireAtBoundary() {
        const QList tasks = {aged("old", Completed, 8), aged("boundary", Stopped, 7), aged("recent", Completed, 6.999),
            aged("running", Running, 20), aged("waiting", Waiting, 20), aged("unknown", Unknown, 20),
            aged("failed", Failed, 20), aged("idle", Idle, 20)};
        auto p = preferences(ids(tasks));
        MonitoringPolicy::reconcile(p, tasks, now);
        QCOMPARE(p.automaticallyRemovedIDs, (QSet<QString>{"old", "boundary"}));
        QCOMPARE(p.selectedIDs, (QSet<QString>{"recent", "running", "waiting", "unknown", "failed", "idle"}));
        QVERIFY(p.excludedIDs.isEmpty());
    }
    void testLatestChildActivityAndUncertainChildrenPreventRetirement() {
        auto root = aged("root", Completed, 30);
        for (const auto &child : {aged("child", Completed, 1, "root"), aged("child", Running, 10, "root"),
                                  aged("child", Waiting, 10, "root"), aged("child", Unknown, 10, "root")}) {
            auto p = preferences({"root"});
            MonitoringPolicy::reconcile(p, {root, child}, now);
            QCOMPARE(p.selectedIDs, QSet<QString>{"root"});
        }
        root.activity.lastEventAt = now;
        auto p = preferences({"root"});
        MonitoringPolicy::reconcile(p, {root}, now);
        QCOMPARE(p.selectedIDs, QSet<QString>{"root"});
    }
    void testRetirementPersistsAndResumedTasksReturnButManualExclusionsDoNot() {
        const auto old = aged("old", Completed, 8);
        auto p = preferences({"old"});
        MonitoringPolicy::reconcile(p, {old}, now);
        p = roundTrip(p);
        MonitoringPolicy::reconcile(p, {old}, now);
        QVERIFY(p.selectedIDs.isEmpty());
        auto resumed = aged("old", Running, 0);
        resumed.updatedAt = at(0);
        resumed.activity.lastEventAt.reset();
        MonitoringPolicy::reconcile(p, {resumed}, now);
        QCOMPARE(p.selectedIDs, QSet<QString>{"old"});
        MonitoringPolicy::applySelection({}, {"old"}, p);
        MonitoringPolicy::reconcile(p, {resumed}, now);
        QVERIFY(p.selectedIDs.isEmpty());
        QCOMPARE(p.excludedIDs, QSet<QString>{"old"});
    }
    void testManualReadditionIsKeptAndDisablingRestoresOnlyAutomaticRemovals() {
        const QList tasks = {aged("restore", Completed, 8), aged("retired", Stopped, 8), aged("manual", Completed, 8)};
        auto p = preferences(ids(tasks));
        MonitoringPolicy::applySelection({"restore", "retired"}, p.selectedIDs, p);
        MonitoringPolicy::reconcile(p, tasks, now);
        MonitoringPolicy::applySelection({"restore"}, {}, p);
        MonitoringPolicy::reconcile(p, tasks, now.addSecs(100 * 86400));
        QCOMPARE(p.selectedIDs, QSet<QString>{"restore"});
        p.finishedRetentionDays = 0;
        MonitoringPolicy::reconcile(p, tasks, now);
        QCOMPARE(p.selectedIDs, (QSet<QString>{"restore", "retired"}));
        QCOMPARE(p.excludedIDs, QSet<QString>{"manual"});
    }
    void testAutoDiscoveryDoesNotReaddExpiredTasksEveryRefresh() {
        auto old = aged("old", Completed, 8);
        old.createdAt = now.addSecs(-9 * 86400);
        auto p = preferences({"old"});
        p.autoMonitor = true;
        p.autoEnabledAt = now.addSecs(-10 * 86400);
        p.autoBaselineIDs.emplace();
        MonitoringPolicy::reconcile(p, {old}, now);
        const auto retired = p;
        MonitoringPolicy::reconcile(p, {old}, now);
        QCOMPARE(p, retired);
        QVERIFY(p.selectedIDs.isEmpty());
    }
    void testLegacyPreferenceDefaultsAndInvalidValue() {
        auto p = roundTrip({});
        QCOMPARE(p.resolvedFinishedRetentionDays(), 7);
        p.finishedRetentionDays = -10;
        QCOMPARE(p.resolvedFinishedRetentionDays(), 7);
    }
    void testMissingOrInvalidTimesAreNotTreatedAsOldActivity() {
        for (const auto &timestamp : {at(0), QDateTime()}) {
            auto missing = aged("missing", Completed, 20);
            missing.updatedAt = timestamp;
            missing.activity.lastEventAt.reset();
            auto p = preferences({"missing"});
            MonitoringPolicy::reconcile(p, {missing}, now);
            QCOMPARE(p.selectedIDs, QSet<QString>{"missing"});
            missing.parentID = "root";
            p = preferences({"root"});
            MonitoringPolicy::reconcile(p, {aged("root", Completed, 20), missing}, now);
            QCOMPARE(p.selectedIDs, QSet<QString>{"root"});
        }
    }
};
QTEST_APPLESS_MAIN(FinishedRetentionTests)
#include "test_finished_retention.moc"
