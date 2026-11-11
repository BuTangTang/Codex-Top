#include "../codex/local_source_fixture.h"
#include "../codex/isolated_codex_source.h"
#include "policy/monitoring_policy.h"

using namespace local_fixture;
class TeamChatSelectionTests : public QObject {
    Q_OBJECT
  private slots:
    void testAutomaticTeamChatCopiesStaySelectableWithoutAutomaticMonitoring() {
        Fixture f;
        const auto imported = f.path("import.jsonl"), native = f.path("native.jsonl");
        const QJsonObject marker{
            {"automatic", true}, {"sourceProject", "fixture-project"}, {"sourceSession", "fixture-session"}};
        const QList<QJsonObject> rows{
            {{"ordinal", 0},
             {"type", "session_meta"},
             {"payload", QJsonObject{{"id", "import"}, {"teamchat_copy", marker}}}},
            {{"ordinal", 1},
             {"type", "event_msg"},
             {"payload",
              QJsonObject{{"type", "task_started"}, {"turn_id", "imported"}, {"root_turn_id", "imported"}}}},
            {{"ordinal", 2},
             {"type", "event_msg"},
             {"payload", QJsonObject{{"type", "agent_message"}, {"phase", "final_answer"}}}},
            {{"type", "event_msg"}, {"payload", QJsonObject{{"type", "thread_settings_applied"}}}}};
        QByteArray history;
        for (const auto &row : rows)
            history += QJsonDocument(row).toJson(QJsonDocument::Compact) + '\n';
        write(imported, history);
        const auto start = local_fixture::event("task_started", now, {{"turn_id", "native-turn"}});
        write(native, start);
        f.add("import", imported, "同名样例");
        f.add("native", native, "同名样例");
        IsolatedCodexSource source(f.root);
        const auto snapshot = source.snapshot(now);
        QCOMPARE(snapshot.tasks.size(), 2);
        QVERIFY(task(snapshot, "import").activity.isTeamChatImport);
        MonitorPreferences prefs;
        prefs.selectedIDs = {"import"};
        MonitoringPolicy::reconcile(prefs, snapshot.tasks, now);
        QCOMPARE(prefs.selectedIDs, QSet<QString>{"native"});
        QVERIFY(prefs.excludedIDs.isEmpty());
        auto manual = prefs;
        MonitoringPolicy::applySelection({"import", "native"}, prefs.selectedIDs, manual);
        MonitoringPolicy::reconcile(manual, snapshot.tasks, now);
        QVERIFY(manual.selectedIDs.contains("import"));
        MonitoringPolicy::applySelection({"native"}, manual.selectedIDs, manual);
        write(imported, start, true);
        const auto resumed = source.snapshot(now);
        const auto activity = task(resumed, "import").activity;
        QCOMPARE(activity.phase, TaskPhase::Running);
        QVERIFY(!activity.isTeamChatImport);
        MonitoringPolicy::reconcile(prefs, resumed.tasks, now);
        QVERIFY(prefs.selectedIDs.contains("import"));
        MonitoringPolicy::reconcile(manual, resumed.tasks, now);
        QVERIFY(!manual.selectedIDs.contains("import"));
    }
};
QTEST_GUILESS_MAIN(TeamChatSelectionTests)
#include "test_team_chat_selection.moc"
