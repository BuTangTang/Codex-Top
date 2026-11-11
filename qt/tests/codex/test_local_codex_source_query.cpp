#include "local_source_fixture.h"
#include <QTextBoundaryFinder>
#include <algorithm>

using namespace local_fixture;
namespace {
// 每个查询用例沿用原生版的一条完成记录与独立数据库。
struct QueryFixture : Fixture {
    QString log = path("rollout.jsonl");
    explicit QueryFixture(bool create = true) : Fixture(create) {
        write(log, local_fixture::event("task_complete"));
    }
};
// 保留快照顺序用于同 SQLite 查询的逐行比对。
QStringList ids(const SourceSnapshot &snapshot) {
    QStringList result;
    for (const auto &item : snapshot.tasks)
        result.append(item.id);
    return result;
}
// 模拟 Swift 原夹具中不同任务共用的起始、结束或回复行。
QByteArray line(QString type, int seconds, QJsonObject extra, QString kind = "event_msg") {
    return local_fixture::event(type, now.addSecs(seconds), extra, kind);
}
// 只取指定列，验证表结构和 SQLite 的实际排序。
QStringList column(const QList<QVariantList> &rows, int index) {
    QStringList out;
    for (const auto &row : rows)
        out << row.at(index).toString();
    return out;
}
// 可选父任务字段保留源文件里的 JSON 形状。
QString spawn(const QString &parent) {
    return QString::fromUtf8(
        QJsonDocument(QJsonObject{{"subagent",
                                   QJsonObject{{"thread_spawn", QJsonObject{{"parent_thread_id", parent}}}}}})
            .toJson(QJsonDocument::Compact));
}
} // namespace
class LocalCodexSourceQueryTests : public QObject {
    Q_OBJECT
  private slots:
    void testWarmTailsKeepPendingHalfLineAndReadOnlyAppendedBytes() {
        QueryFixture f;
        const auto waiting = f.path("waiting.jsonl"), other = f.path("other.jsonl");
        const auto begin = line("task_started", -20, {{"turn_id", "waiting-turn"}});
        const auto question =
            line("function_call", -10, {{"name", "request_user_input"}, {"call_id", "synthetic-call"}},
                 "response_item");
        const auto otherBegin = line("task_started", -30, {{"turn_id", "other-turn"}});
        write(waiting, begin + question);
        write(other, otherBegin);
        f.add("waiting", waiting, "合成待答", "/synthetic", 2);
        f.add("other", other, "合成运行", "/synthetic", 1);
        LocalCodexSource source(f.root);
        const auto first = source.snapshot(now);
        QCOMPARE(first.bytesRead, begin.size() + question.size() + otherBegin.size());
        const auto original = task(first, "waiting");
        QCOMPARE(original.activity.phase, TaskPhase::Waiting);
        QCOMPARE(original.activity.startedAt, now.addSecs(-20));
        QCOMPARE(original.activity.turnID, QString("waiting-turn"));
        const auto warm = source.snapshot(now);
        QCOMPARE(warm.tasks, first.tasks);
        QCOMPARE(warm.bytesRead, 0);
        const auto reply = line("function_call_output", -5,
                                {{"call_id", "synthetic-call"}, {"output", "合成🙂"}}, "response_item");
        const auto split = reply.size() / 2;
        write(waiting, reply.left(split), true);
        const auto partial = source.snapshot(now), repeat = source.snapshot(now);
        QCOMPARE(partial.bytesRead, split);
        QCOMPARE(partial.tasks, first.tasks);
        QCOMPARE(repeat.bytesRead, 0);
        QCOMPARE(repeat.tasks, first.tasks);
        write(waiting, reply.mid(split), true);
        const auto complete = source.snapshot(now);
        QCOMPARE(complete.bytesRead, reply.size() - split);
        const auto resumed = task(complete, "waiting");
        QCOMPARE(resumed.activity.phase, TaskPhase::Running);
        QCOMPARE(resumed.activity.detail, "已收到回答，正在继续");
        QCOMPARE(resumed.activity.startedAt, now.addSecs(-20));
        QCOMPARE(resumed.activity.turnID, QString("waiting-turn"));
        QCOMPARE(resumed.activity.lastEventAt, now.addSecs(-5));
        QCOMPARE(task(complete, "other"), task(first, "other"));
        QVERIFY(!complete.warning);
        const auto stable = source.snapshot(now);
        QCOMPARE(stable.tasks, complete.tasks);
        QCOMPARE(stable.bytesRead, 0);
    }
    void testArchiveReopenReadsRemovedTailsWithoutReReadingRetainedFiles() {
        QueryFixture f;
        const auto original = line("task_complete", -20, {{"turn_id", "original-turn"}});
        QStringList logs;
        for (int i = 0; i < 65; ++i) {
            logs << f.path(QString("archive-%1.jsonl").arg(i));
            write(logs.last(), original);
            f.add(QString("tail-%1").arg(i), logs.last(), "合成归档");
        }
        LocalCodexSource source(f.root);
        const auto initial = source.snapshot(now);
        QCOMPARE(initial.tasks.size(), logs.size());
        QCOMPARE(initial.bytesRead, original.size() * logs.size());
        f.sql("UPDATE threads SET archived=1 WHERE id<>'tail-0'");
        const auto archived = source.snapshot(now);
        QCOMPARE(ids(archived), QStringList{"tail-0"});
        QCOMPARE(archived.bytesRead, 0);
        const auto newTurn = line("task_started", -5, {{"turn_id", "new-turn"}});
        for (const auto &log : logs)
            write(log, newTurn, true);
        const auto retained = source.snapshot(now);
        QCOMPARE(retained.bytesRead, newTurn.size());
        QCOMPARE(task(retained, "tail-0").activity.phase, TaskPhase::Running);
        QCOMPARE(task(retained, "tail-0").activity.turnID, QString("new-turn"));
        f.sql("UPDATE threads SET archived=0");
        const auto reopened = source.snapshot(now);
        QCOMPARE(reopened.tasks.size(), logs.size());
        QCOMPARE(reopened.bytesRead, (original.size() + newTurn.size()) * (logs.size() - 1));
        QCOMPARE(task(reopened, "tail-0"), retained.tasks.first());
        for (const auto &t : reopened.tasks) {
            QCOMPARE(t.activity.phase, TaskPhase::Running);
            QCOMPARE(t.activity.turnID, QString("new-turn"));
        }
        QVERIFY(!reopened.warning);
        const auto unchanged = source.snapshot(now);
        QCOMPARE(unchanged.bytesRead, 0);
        QCOMPARE(unchanged.tasks, reopened.tasks);
        f.sql("UPDATE threads SET archived=1");
        const auto empty = source.snapshot(now);
        QVERIFY(empty.tasks.isEmpty());
        QCOMPARE(empty.bytesRead, 0);
        f.sql("UPDATE threads SET archived=0 WHERE id='tail-0'");
        const auto after = source.snapshot(now);
        QCOMPARE(after.tasks, retained.tasks);
        QCOMPARE(after.bytesRead, original.size() + newTurn.size());
    }
    void testAllFailedTailsRecoverFromFreshFilesWithoutOldReducerState() {
        QueryFixture f;
        const QStringList logs{f.path("failed-a.jsonl"), f.path("failed-b.jsonl")};
        const auto running = line("task_started", -20, {{"turn_id", "old-turn"}});
        for (int i = 0; i < logs.size(); ++i) {
            write(logs[i], running);
            f.add(QString("failed-%1").arg(i), logs[i], "合成缺失");
        }
        LocalCodexSource source(f.root);
        const auto initial = source.snapshot(now);
        QCOMPARE(initial.bytesRead, running.size() * logs.size());
        for (const auto &t : initial.tasks) {
            QCOMPARE(t.activity.phase, TaskPhase::Running);
            QVERIFY(t.activity.startedAt);
        }
        for (const auto &log : logs)
            QVERIFY(QFile::remove(log));
        const auto failed = source.snapshot(now);
        QCOMPARE(failed.tasks.size(), logs.size());
        for (const auto &t : failed.tasks) {
            QCOMPARE(t.activity.phase, TaskPhase::Unknown);
            QVERIFY(!t.activity.startedAt);
        }
        QCOMPARE(failed.bytesRead, 0);
        QVERIFY(failed.warning);
        const auto missing = source.snapshot(now);
        QCOMPARE(missing.tasks, failed.tasks);
        QCOMPARE(missing.bytesRead, 0);
        const auto finished = line("task_complete", -5, {{"turn_id", "fresh-turn"}});
        for (const auto &log : logs)
            write(log, finished);
        const auto restored = source.snapshot(now);
        QCOMPARE(restored.bytesRead, finished.size() * logs.size());
        for (const auto &t : restored.tasks) {
            QCOMPARE(t.activity.phase, TaskPhase::Completed);
            QVERIFY(!t.activity.startedAt && !t.activity.turnID);
        }
        QVERIFY(!restored.warning);
        const auto warm = source.snapshot(now);
        QCOMPARE(warm.tasks, restored.tasks);
        QCOMPARE(warm.bytesRead, 0);
    }
    void testPartialFailedTailsRecoverWithoutResettingRetainedTail() {
        QueryFixture f;
        QStringList logs;
        const auto original = line("task_complete", -20, {{"turn_id", "original-turn"}});
        for (int i = 0; i < 65; ++i) {
            logs << f.path(QString("partial-failure-%1.jsonl").arg(i));
            write(logs.last(), original);
            f.add(QString("partial-%1").arg(i), logs.last(), "合成部分失败");
        }
        LocalCodexSource source(f.root);
        const auto initial = source.snapshot(now);
        QCOMPARE(initial.bytesRead, original.size() * logs.size());
        for (const auto &log : logs.mid(1))
            QVERIFY(QFile::remove(log));
        const auto failed = source.snapshot(now);
        QCOMPARE(failed.tasks.size(), logs.size());
        QCOMPARE(std::count_if(failed.tasks.begin(), failed.tasks.end(),
                               [](const auto &t) { return t.activity.phase == TaskPhase::Unknown; }),
                 logs.size() - 1);
        QCOMPARE(task(failed, "partial-0"), task(initial, "partial-0"));
        QCOMPARE(failed.bytesRead, 0);
        QVERIFY(failed.warning);
        const auto keep = line("task_started", -5, {{"turn_id", "retained-turn"}});
        write(logs.first(), keep, true);
        const auto retained = source.snapshot(now);
        QCOMPARE(retained.bytesRead, keep.size());
        QCOMPARE(task(retained, "partial-0").activity.turnID, QString("retained-turn"));
        const auto fresh = line("task_complete", -5, {{"turn_id", "fresh-turn"}});
        for (const auto &log : logs.mid(1))
            write(log, fresh);
        const auto restored = source.snapshot(now);
        QCOMPARE(restored.bytesRead, fresh.size() * (logs.size() - 1));
        QCOMPARE(task(restored, "partial-0"), task(retained, "partial-0"));
        for (const auto &t : restored.tasks)
            if (t.id != "partial-0") {
                QCOMPARE(t.activity.phase, TaskPhase::Completed);
                QVERIFY(!t.activity.startedAt);
            }
        QVERIFY(!restored.warning);
    }
    void testLargeHistoryLabelsStayCurrentAcrossReplacementAndArchive() {
        QueryFixture f;
        f.sql("ALTER TABLE threads ADD COLUMN source TEXT");
        f.sql("WITH RECURSIVE numbers(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM numbers WHERE n<2199) "
              "INSERT INTO threads SELECT printf('cache-%04d',n),'合成标题 ' || "
              "n,'/synthetic/project',?,1,n,0,? FROM numbers",
              {f.log, spawn("old-parent")});
        LocalCodexSource source(f.root);
        const auto initial = source.snapshot(now);
        QCOMPARE(initial.tasks.size(), 2200);
        for (const auto &t : initial.tasks) {
            QCOMPARE(t.parentID, QString("old-parent"));
            QCOMPARE(t.activity.phase, TaskPhase::Completed);
        }
        const auto warm = source.snapshot(now);
        QCOMPARE(warm.tasks, initial.tasks);
        QCOMPARE(warm.bytesRead, 0);
        f.sql("UPDATE threads SET title=?,source=NULL", {QString("改🙂").repeated(900)});
        const auto replaced = source.snapshot(now);
        QCOMPARE(replaced.tasks.size(), 2200);
        for (const auto &t : replaced.tasks) {
            QCOMPARE(t.title, QString("改🙂").repeated(150));
            QVERIFY(!t.parentID);
        }
        QCOMPARE(replaced.bytesRead, 0);
        f.sql("UPDATE threads SET archived=1 WHERE id<'cache-2100'");
        f.sql("UPDATE threads SET title='短标题',source=?", {spawn("new-parent")});
        const auto archived = source.snapshot(now);
        QCOMPARE(archived.tasks.size(), 100);
        for (const auto &t : archived.tasks) {
            QCOMPARE(t.title, "短标题");
            QCOMPARE(t.parentID, QString("new-parent"));
        }
        f.sql("UPDATE threads SET archived=0");
        const auto restored = source.snapshot(now);
        QCOMPARE(restored.tasks.size(), 2200);
        for (const auto &t : restored.tasks) {
            QCOMPARE(t.title, "短标题");
            QCOMPARE(t.parentID, QString("new-parent"));
            QCOMPARE(t.activity.phase, TaskPhase::Completed);
        }
        QVERIFY(!restored.warning);
    }
    void testMainRowsPreserveStorageClassesDatesAndEmbeddedNUL() {
        QueryFixture f(false);
        f.sql("CREATE TABLE threads(id,title,cwd,rollout_path,created_at,updated_at,archived,source)");
        const QList<std::pair<QString, double>> values{{"NULL", 0},
                                                       {"''", 0},
                                                       {"'invalid'", 0},
                                                       {"17", 17},
                                                       {"17.25", 17.25},
                                                       {"'2e3'", 2000},
                                                       {"'-23.75'", -23.75},
                                                       {"'0x1p4'", 16},
                                                       {"X'34322E35003939'", 42.5},
                                                       {"X'FF'", 0},
                                                       {"'7' || char(0) || '99'", 7}};
        for (int i = 0; i < values.size(); ++i)
            f.sql(QString("INSERT INTO threads VALUES(?,123,456,?,%1,%1,0,NULL)").arg(values[i].first),
                  {QString("storage-%1").arg(i), f.log});
        f.sql(
            "INSERT INTO threads VALUES('nul-id' || char(0) || 'ignored',X'41FF420043','/synthetic/project' "
            "|| char(0) || 'ignored',? || char(0) || '/not-a-file',1,2,0,"
            "'{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"parent\"}}}' || char(0) || 'ignored')",
            {f.log});
        QCOMPARE(column(f.select("SELECT typeof(created_at) FROM threads WHERE id IN "
                                 "('storage-0','storage-3','storage-4','storage-5','storage-8') ORDER BY id"),
                        0),
                 (QStringList{"null", "integer", "real", "text", "blob"}));
        const auto snap = LocalCodexSource(f.root).snapshot(now);
        QCOMPARE(snap.tasks.size(), values.size() + 1);
        for (int i = 0; i < values.size(); ++i) {
            const auto &t = task(snap, QString("storage-%1").arg(i));
            QVERIFY(std::abs(t.createdAt.toMSecsSinceEpoch() / 1000.0 - values[i].second) < 0.000001);
            QVERIFY(std::abs(t.updatedAt.toMSecsSinceEpoch() / 1000.0 - values[i].second) < 0.000001);
            QCOMPARE(t.title, "123");
            QCOMPARE(t.project, "456");
        }
        const auto &nul = task(snap, "nul-id");
        QCOMPARE(nul.title, QStringLiteral("A\uFFFDB"));
        QCOMPARE(nul.project, "project");
        QCOMPARE(nul.parentID, QString("parent"));
        QCOMPARE(nul.rolloutPath, QFileInfo(f.log).canonicalFilePath());
        for (const auto &t : snap.tasks)
            QCOMPARE(t.activity.phase, TaskPhase::Completed);
        QVERIFY(!snap.warning);
    }
    void testMainRowsKeepSQLiteOrderingAcrossIndexChanges() {
        QueryFixture f;
        const QList<std::pair<QString, QString>> rows{{"low", "1"},    {"tie-z", "10"},
                                                      {"high", "30"},  {"tie-a", "10"},
                                                      {"tie-m", "10"}, {"null-time", "NULL"}};
        for (const auto &[id, updated] : rows)
            f.sql(QString("INSERT INTO threads VALUES(?,?,?,?,1,%1,0)").arg(updated),
                  {id, id, "/synthetic/project", f.log});
        f.sql("INSERT INTO threads VALUES(NULL,'missing id','/synthetic/project',?,1,100,0)", {f.log});
        f.sql("INSERT INTO threads VALUES('missing-path','missing path','/synthetic/project',NULL,1,100,0)");
        f.sql("INSERT INTO threads VALUES('archived','archived','/synthetic/project',?,1,1000,1)", {f.log});
        LocalCodexSource source(f.root);
        for (bool indexed : {false, true}) {
            if (indexed)
                f.sql("CREATE INDEX threads_updated_idx ON threads(updated_at)");
            const auto ordered =
                f.select("SELECT id,title,cwd,rollout_path,created_at,updated_at,'' AS source "
                         "FROM threads WHERE archived=0 ORDER BY updated_at DESC");
            QStringList expected;
            for (const auto &row : ordered)
                if (!row[3].isNull() && !row[0].isNull())
                    expected.append(row[0].toString());
            const auto snap = source.snapshot(now);
            const auto actual = ids(snap);
            QCOMPARE(actual, expected);
            QCOMPARE(actual.first(), "high");
            QCOMPARE(actual.last(), "null-time");
            const auto middle = actual.mid(1, actual.size() - 2);
            QCOMPARE(QSet<QString>(middle.begin(), middle.end()),
                     (QSet<QString>{"tie-z", "tie-a", "tie-m", "low"}));
            if (indexed)
                QCOMPARE(snap.bytesRead, 0);
        }
    }
    void testMainQueryPrepareAndStepFailuresRecoverOnSameSource() {
        QueryFixture f(false);
        f.sql("CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at "
              "INTEGER,updated_at TEXT COLLATE NOCASE,archived INTEGER)");
        f.sql("INSERT INTO threads VALUES('root','测试','/synthetic/project',?,1,2,0)", {f.log});
        // 原生夹具只在写库时注册 synthetic_order。Qt SQLite 未导出注册接口，在临时库的
        // schema 中还原完全相同的 COLLATE 子句，使生产连接遇到相同的 prepare 错误。
        f.sql("PRAGMA writable_schema=ON");
        f.sql("UPDATE sqlite_schema SET sql=replace(sql,'COLLATE NOCASE','COLLATE synthetic_order') WHERE "
              "name='threads'");
        f.sql("PRAGMA writable_schema=OFF");
        f.sql("PRAGMA schema_version=2");
        const QStringList fields{"id",         "title",      "cwd",     "rollout_path",
                                 "created_at", "updated_at", "archived"};
        QCOMPARE(column(f.select("PRAGMA table_info(threads)"), 1), fields);
        LocalCodexSource source(f.root);
        try {
            source.snapshot(now);
            QFAIL("主查询缺少排序规则时必须报告 prepare 失败");
        } catch (CodexSourceError e) {
            QCOMPARE(e, CodexSourceError::IncompatibleDatabase);
        }
        f.sql("DROP TABLE threads");
        f.sql(schema);
        f.sql("INSERT INTO threads VALUES('root','已恢复','/synthetic/project',?,1,2,0)", {f.log});
        const auto recovered = source.snapshot(now);
        QCOMPARE(task(recovered, "root").title, "已恢复");
        f.sql("ALTER TABLE threads RENAME TO backing_threads");
        f.sql("CREATE VIEW threads AS SELECT id,title,cwd,rollout_path,created_at,"
              "abs(-9223372036854775808) AS updated_at,archived FROM backing_threads");
        QCOMPARE(column(f.select("PRAGMA table_info(threads)"), 1), fields);
        try {
            source.snapshot(now);
            QFAIL("主查询整数溢出时必须报告 step 失败");
        } catch (CodexSourceError e) {
            QCOMPARE(e, CodexSourceError::DatabaseUnavailable);
        }
        f.sql("DROP VIEW threads");
        f.sql("ALTER TABLE backing_threads RENAME TO threads");
        const auto restored = source.snapshot(now);
        QCOMPARE(restored.tasks, recovered.tasks);
        QCOMPARE(restored.bytesRead, 0);
    }
    void testMalformedEdgeTableFallsBackAndRecoversOnSameSource() {
        QueryFixture f;
        f.sql("ALTER TABLE threads ADD COLUMN source TEXT");
        f.sql("CREATE TABLE thread_spawn_edges(unrelated TEXT)");
        f.sql("INSERT INTO threads VALUES('child','测试','/synthetic/project',?,1,2,0,?)",
              {f.log, spawn("source-parent")});
        LocalCodexSource source(f.root);
        const auto fallback = source.snapshot(now);
        QCOMPARE(task(fallback, "child").parentID, QString("source-parent"));
        QVERIFY(!fallback.warning);
        f.sql("DROP TABLE thread_spawn_edges");
        f.sql("CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)");
        f.sql("INSERT INTO thread_spawn_edges VALUES('edge-parent','child'),(NULL,'child'),('ignored',NULL)");
        const auto repaired = source.snapshot(now);
        QCOMPARE(task(repaired, "child").parentID, QString("edge-parent"));
        QCOMPARE(repaired.bytesRead, 0);
        f.sql("ALTER TABLE thread_spawn_edges RENAME COLUMN parent_thread_id TO unrelated");
        const auto broken = source.snapshot(now);
        QCOMPARE(task(broken, "child").parentID, QString("source-parent"));
        QVERIFY(!broken.warning);
        QCOMPARE(broken.bytesRead, 0);
    }
};
QTEST_GUILESS_MAIN(LocalCodexSourceQueryTests)
#include "test_local_codex_source_query.moc"
