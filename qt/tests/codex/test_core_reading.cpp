#include "isolated_codex_source.h"
#include "codex/local_codex_source.h"
#include "codex/rollout_reducer.h"
#include <QJsonDocument>
#include <QSaveFile>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QUuid>
#include <QtTest>

using namespace codextop;
namespace {
const auto timeBase = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);

// 保留 CoreTests 的固定时刻、事件类型和负载，仅用合成记录。
QByteArray eventRecord(QString type, int seconds = 0, QJsonObject payload = {}, QString kind = "event_msg") {
    payload["type"] = type;
    return QJsonDocument(QJsonObject{{"timestamp", timeBase.addSecs(seconds).toString(Qt::ISODate)},
                                     {"type", kind},
                                     {"payload", payload}})
        .toJson(QJsonDocument::Compact);
}
// 写入并关闭测试文件，供下一轮按增量或截断读取。
bool writeFile(const QString &path, const QByteArray &data, bool append = false) {
    QFile f(path);
    return f.open(QIODevice::WriteOnly | (append ? QIODevice::Append : QIODevice::Truncate)) &&
           f.write(data) == data.size();
}
// 独立的 SQLite 连接只用于准备合成输入，开始快照前彻底关闭。
bool database(const QString &path, const QStringList &statements) {
    const auto name = QUuid::createUuid().toString();
    bool ok;
    {
        auto db = QSqlDatabase::addDatabase("QSQLITE", name);
        db.setDatabaseName(path);
        ok = db.open();
        for (const auto &sql : statements)
            ok = ok && QSqlQuery(db).exec(sql);
    }
    QSqlDatabase::removeDatabase(name);
    return ok;
}
} // namespace
class CoreReadingTests : public QObject {
    Q_OBJECT
  private slots:
    void testLifecycleResumeAndLateCompletion() {
        RolloutReducer r;
        r.consume(eventRecord("task_started", 0, {{"turn_id", "first"}}));
        r.consume(eventRecord("task_complete", 10, {{"turn_id", "first"}}));
        QCOMPARE(r.activity.phase, TaskPhase::Completed);
        r.consume(eventRecord("task_started", 20, {{"turn_id", "second"}}));
        r.consume(eventRecord("task_complete", 21, {{"turn_id", "first"}}));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
        QCOMPARE(r.activity.startedAt, timeBase.addSecs(20));
        r.consume(eventRecord("turn_aborted", 22));
        QCOMPARE(r.activity.phase, TaskPhase::Stopped);
    }
    void testEveryTerminalEventIgnoresAnOlderTurnAndAcceptsTheCurrentTurn() {
        const QList<std::pair<QString, TaskPhase>> terminals{
            {"task_complete", TaskPhase::Completed}, {"turn_complete", TaskPhase::Completed},
            {"turn_aborted", TaskPhase::Stopped},    {"task_cancelled", TaskPhase::Stopped},
            {"turn_cancelled", TaskPhase::Stopped},  {"task_failed", TaskPhase::Failed},
            {"turn_failed", TaskPhase::Failed}};
        for (const auto &[type, phase] : terminals) {
            RolloutReducer r;
            r.consume(eventRecord("task_started", 0, {{"turn_id", "first"}}));
            r.consume(eventRecord("task_complete", 1, {{"turn_id", "first"}}));
            r.consume(eventRecord("task_started", 2, {{"turn_id", "second"}}));
            r.consume(eventRecord(type, 3, {{"turn_id", "first"}}));
            QCOMPARE(r.activity.phase, TaskPhase::Running);
            QCOMPARE(r.activity.turnID, QString("second"));
            QCOMPARE(r.activity.lastEventAt, timeBase.addSecs(2));
            r.consume(eventRecord(type, 4, {{"turn_id", "second"}}));
            QCOMPARE(r.activity.phase, phase);
        }
    }
    void testFailedTurnSurvivesTrailingMessagesToolsAndCompletionWhileQuotaStillUpdates() {
        struct Entry {
            QString kind, type;
            QJsonObject extra;
        };
        const QList<Entry> trailing{
            {"event_msg", "agent_message", {}},
            {"event_msg", "agent_reasoning", {}},
            {"event_msg", "item_completed", {{"item", QJsonObject{{"type", "commandExecution"}}}}},
            {"event_msg", "request_user_input", {}},
            {"event_msg", "task_complete", {{"turn_id", "failed"}}},
            {"response_item", "function_call", {{"name", "exec_command"}}},
            {"response_item", "custom_tool_call", {{"name", "request_user_input"}, {"call_id", "question"}}},
            {"response_item", "function_call_output", {{"call_id", "question"}}}};
        for (const auto failure : {"task_failed", "turn_failed"}) {
            RolloutReducer r;
            r.consume(eventRecord("task_started", 0, {{"turn_id", "failed"}}));
            r.consume(eventRecord(failure, 1, {{"turn_id", "failed"}}));
            int seconds = 2;
            for (const auto &e : trailing) {
                r.consume(eventRecord(e.type, seconds++, e.extra, e.kind));
                QCOMPARE(r.activity.phase, TaskPhase::Failed);
                QCOMPARE(r.activity.turnID, QString("failed"));
            }
            const QJsonObject limits{
                {"limit_id", "codex"},
                {"primary", QJsonObject{{"used_percent", 19.0}, {"window_minutes", 300}}}};
            r.consume(eventRecord("token_count", 20, {{"rate_limits", limits}}));
            QCOMPARE(r.activity.phase, TaskPhase::Failed);
            QVERIFY(r.quota && r.quota->fiveHour());
            QCOMPARE(r.quota->fiveHour()->remainingPercent(), 81);
        }
    }
    void testFailedTurnResumesOnlyOnExplicitStartOrUserContinuation() {
        struct Resume {
            QString type;
            QJsonObject fields;
            std::optional<QString> turn;
        };
        const QList<Resume> cases{{"task_started", {{"turn_id", "resumed"}}, "resumed"},
                                  {"turn_started", {{"turn_id", "resumed"}}, "resumed"},
                                  {"user_message", {}, {}},
                                  {"user_input", {}, {}},
                                  {"approval_resolved", {}, {}},
                                  {"item_completed", {{"item", QJsonObject{{"type", "userMessage"}}}}, {}}};
        for (const auto &c : cases) {
            RolloutReducer r;
            r.consume(eventRecord("task_started", 0, {{"turn_id", "failed"}}));
            r.consume(eventRecord("task_failed", 1));
            r.consume(eventRecord(c.type, 2, c.fields));
            QCOMPARE(r.activity.phase, TaskPhase::Running);
            QCOMPARE(r.activity.startedAt, timeBase.addSecs(2));
            QCOMPARE(r.activity.turnID, c.turn);
        }
    }
    void testWaitingOnlyResolvesOnMatchingAnswer() {
        RolloutReducer r;
        r.consume(eventRecord("function_call", 0, {{"name", "request_user_input"}, {"call_id", "question"}},
                              "response_item"));
        r.consume(eventRecord("function_call_output", 0, {{"call_id", "unrelated"}}, "response_item"));
        QCOMPARE(r.activity.phase, TaskPhase::Waiting);
        r.consume(eventRecord("function_call_output", 0, {{"call_id", "question"}}, "response_item"));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
    }
    void testAsyncQuestionDoesNotResolveOnToolReturnOrTurnComplete() {
        RolloutReducer r;
        r.consume(eventRecord("function_call", 0,
                              {{"name", "request_user_input_async"}, {"call_id", "question"}},
                              "response_item"));
        r.consume(eventRecord("function_call_output", 0, {{"call_id", "question"}}, "response_item"));
        r.consume(eventRecord("task_complete"));
        QCOMPARE(r.activity.phase, TaskPhase::Waiting);
        r.consume(eventRecord("user_message"));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
    }
    void testStaleRunningIsUnknownButFinishedAndWaitingRemain() {
        TaskActivity a;
        a.lastEventAt = timeBase.addSecs(-1000);
        a.phase = TaskPhase::Running;
        QCOMPARE(a.effective(timeBase).phase, TaskPhase::Unknown);
        for (auto phase : {TaskPhase::Completed, TaskPhase::Waiting}) {
            a.phase = phase;
            QCOMPARE(a.effective(timeBase).phase, phase);
        }
    }
    void testQuotaIdentifiesWindowByDurationNotPosition() {
        RolloutReducer r;
        const QJsonObject limits{{"limit_id", "codex"},
                                 {"primary", QJsonObject{{"used_percent", 85.0}, {"window_minutes", 10080}}},
                                 {"secondary", QJsonObject{{"used_percent", 19.0}, {"window_minutes", 300}}}};
        r.consume(eventRecord("token_count", 0, {{"rate_limits", limits}}));
        QVERIFY(r.quota && r.quota->weekly() && r.quota->fiveHour());
        QCOMPARE(r.quota->weekly()->remainingPercent(), 15);
        QCOMPARE(r.quota->fiveHour()->remainingPercent(), 81);
    }
    void testMalformedAndOutOfOrderEventsDoNotCorruptState() {
        RolloutReducer r;
        r.consume(eventRecord("task_complete"));
        r.consume("garbage");
        r.consume(eventRecord("task_started", -1));
        QCOMPARE(r.activity.phase, TaskPhase::Completed);
    }
    void testIncrementalPartialLineTruncationAndNoReread() {
        QTemporaryDir root;
        const auto path = root.filePath("rollout.jsonl");
        const auto first = eventRecord("task_started") + '\n', complete = eventRecord("task_complete");
        QVERIFY(writeFile(path, first));
        IncrementalRollout tail;
        QCOMPARE(tail.refresh(path), first.size());
        QCOMPARE(tail.refresh(path), 0);
        QVERIFY(writeFile(path, complete.left(15), true));
        tail.refresh(path);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Running);
        QVERIFY(writeFile(path, complete.mid(15) + '\n', true));
        tail.refresh(path);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Completed);
        QSaveFile replacement(path);
        QVERIFY(replacement.open(QIODevice::WriteOnly));
        const auto aborted = eventRecord("turn_aborted") + '\n';
        QCOMPARE(replacement.write(aborted), aborted.size());
        QVERIFY(replacement.commit());
        tail.refresh(path);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Stopped);
    }
    void testLargeHistoryIsBoundedAndRecoversAfterOversizeLine() {
        QTemporaryDir root;
        const auto path = root.filePath("rollout.jsonl");
        QVERIFY(writeFile(path, QByteArray(5000, 'x') + '\n' + eventRecord("task_complete") + '\n'));
        IncrementalRollout tail(1000);
        QVERIFY(tail.refresh(path) <= 1024);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Completed);
    }
    void testRealSQLiteReadOnlyAdapterFiltersArchivesAndBlocksOutsidePaths() {
        QTemporaryDir root;
        const auto db = root.filePath("state_5.sqlite"), log = root.filePath("rollout.jsonl");
        QVERIFY(writeFile(log, eventRecord("task_complete") + '\n'));
        QString escaped = log;
        escaped.replace("'", "''");
        QVERIFY(database(
            db,
            {"CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at "
             "INTEGER,updated_at INTEGER,archived INTEGER)",
             QString("INSERT INTO threads VALUES('live','Demo','/example/Demo','%1',1,2,0)").arg(escaped),
             QString("INSERT INTO threads VALUES('archived','Old','/example/Old','%1',1,2,1)").arg(escaped),
             "INSERT INTO threads VALUES('outside','Outside','/example/Other','/tmp/outside.jsonl',1,2,0)"}));
        QFile originalFile(db);
        QVERIFY(originalFile.open(QIODevice::ReadOnly));
        const auto original = originalFile.readAll();
        originalFile.close();
        IsolatedCodexSource source(root.path());
        const auto snapshot = source.snapshot(timeBase);
        QCOMPARE(snapshot.tasks.size(), 2);
        QHash<QString, TaskPhase> phases;
        for (const auto &t : snapshot.tasks)
            phases.insert(t.id, t.activity.phase);
        QVERIFY(phases.contains("live") && phases.contains("outside"));
        QCOMPARE(phases["live"], TaskPhase::Completed);
        QCOMPARE(phases["outside"], TaskPhase::Unknown);
        QVERIFY(snapshot.warning.has_value());
        QCOMPARE(source.snapshot(timeBase).bytesRead, 0);
        QVERIFY(originalFile.open(QIODevice::ReadOnly));
        QCOMPARE(originalFile.readAll(), original);
    }
    void testMissingAndUnsupportedDatabaseHaveActionableErrors() {
        QTemporaryDir root;
        try {
            IsolatedCodexSource(root.path()).snapshot();
            QFAIL("missing database should fail");
        } catch (CodexSourceError e) {
            QVERIFY(errorDescription(e).contains("未找到"));
        }
        QVERIFY(database(root.filePath("state_99.sqlite"), {"CREATE TABLE threads(other TEXT)"}));
        try {
            IsolatedCodexSource(root.path()).snapshot();
            QFAIL("unsupported schema should fail");
        } catch (CodexSourceError e) {
            QVERIFY(errorDescription(e).contains("格式不受支持"));
        }
    }
};
QTEST_GUILESS_MAIN(CoreReadingTests)
#include "test_core_reading.moc"
