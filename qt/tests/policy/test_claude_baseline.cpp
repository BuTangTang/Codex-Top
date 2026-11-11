#include "policy_fixture.h"
#include <QJsonDocument>
using namespace policy_test;
namespace {
CodexTask session(const QString &id, TaskPhase phase) {
    auto t = task(id, phase);
    t.origin = TaskOrigin::ClaudeCode;
    t.project = "p";
    t.rolloutPath = "/synthetic.jsonl";
    t.activity = {};
    t.activity.phase = phase;
    return t;
}
}
class ClaudeBaselineTests : public QObject {
    Q_OBJECT
private slots:
    void testFirstAppearanceSelectsActiveAndBaselinesTheRest() {
        MonitorPreferences p;
        p.initialized = true;
        p.autoBaselineIDs = QSet<QString>{"codex-old"};
        p.excludedIDs = {"cc:hidden"};
        MonitoringPolicy::applyClaudeBaseline(p, {session("cc:run", TaskPhase::Running), session("cc:ask", TaskPhase::Waiting),
            session("cc:done", TaskPhase::Completed), session("cc:hidden", TaskPhase::Running)});
        QCOMPARE(p.selectedIDs, (QSet<QString>{"cc:run", "cc:ask"}));
        QCOMPARE(p.autoBaselineIDs, (QSet<QString>{"codex-old", "cc:run", "cc:ask", "cc:done", "cc:hidden"}));
        QCOMPARE(p.claudeBaselineApplied, true);
        MonitoringPolicy::applyClaudeBaseline(p, {session("cc:new", TaskPhase::Running)});
        QVERIFY(!p.autoBaselineIDs->contains("cc:new"));
    }
    void testNoSessionsOrFirstLaunchLeaveRulesToReconcile() {
        MonitorPreferences p;
        MonitoringPolicy::applyClaudeBaseline(p, {});
        QVERIFY(!p.claudeBaselineApplied);
        MonitoringPolicy::applyClaudeBaseline(p, {session("cc:run", TaskPhase::Running)});
        QCOMPARE(p.claudeBaselineApplied, true);
        QVERIFY(p.selectedIDs.isEmpty());
    }
    void testOldPreferencesWithoutClaudeFieldsStillDecode() {
        auto object = MonitorPreferences{}.toJson();
        for (const auto key : {"claudeEnabled", "claudeHome", "claudeBaselineApplied"})
            object.remove(key);
        const auto p = MonitorPreferences::fromJson(QJsonDocument::fromJson(QJsonDocument(object).toJson()).object());
        QVERIFY(p.resolvedClaudeEnabled());
    }
};
QTEST_APPLESS_MAIN(ClaudeBaselineTests)
#include "test_claude_baseline.moc"
