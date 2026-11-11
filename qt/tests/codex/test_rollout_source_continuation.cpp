#include "isolated_codex_source.h"
// Swift 的 IncrementalRolloutTests、RecoveryTests、LongWaitReplyTests 中依赖 LocalCodexSource 的五个用例。
#include "rollout_test_support.h"
#include "codex/local_codex_source.h"
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
using namespace rolloutFixture;

class RolloutSourceContinuationTests : public QObject {
    Q_OBJECT
    /// 在独立目录建最小合成库，关闭它后才交给正式只读数据源。
    static void makeDatabase(const QTemporaryDir &dir, const QStringList &ids, bool edges = false) {
        const auto name = QUuid::createUuid().toString();
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE",name);
            db.setDatabaseName(dir.filePath("state_5.sqlite"));
            QVERIFY(db.open());
            QSqlQuery query(db);
            QVERIFY(query.exec("CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)"));
            for (const auto &id : ids) {
                QVERIFY(query.prepare("INSERT INTO threads VALUES(?,'Synthetic',?,?,1,2,0)"));
                query.addBindValue(id);
                query.addBindValue(edges ? "/example" : "/example/Synthetic");
                query.addBindValue(dir.filePath((edges ? id : QString("rollout")) + ".jsonl"));
                QVERIFY(query.exec());
            }
            if (edges) {
                QVERIFY(query.exec("CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)"));
                QVERIFY(query.exec("INSERT INTO thread_spawn_edges VALUES('root','child'),('child','grandchild')"));
            }
        }
        QSqlDatabase::removeDatabase(name);
    }
    /// 建一轮待答，方便长时间无追加与随后恢复场景共用。
    static void makeWaiting(const QTemporaryDir &dir) {
        overwrite(dir.filePath("rollout.jsonl"),initialQuestion(10,"first"));
        makeDatabase(dir,{"fixture"});
    }
    /// 完整构造正式用户回复使用的卡片包装。
    static QByteArray reply(const QString &id, int seconds) {
        const auto item = QJsonDocument(QJsonArray{"request_user_input_async",id,0}).toJson(QJsonDocument::Compact);
        const QJsonArray answers{QJsonObject{{"questionItemId",QString::fromUtf8(item)},{"question","Synthetic question"},{"answer","Synthetic answer"}}};
        const auto text = QString("<send_user_message_question_reply>\n%1\n</send_user_message_question_reply>")
                              .arg(QString::fromUtf8(QJsonDocument(answers).toJson(QJsonDocument::Compact)));
        return lines({response("message",seconds,{{"role","user"},{"content",QJsonArray{QJsonObject{{"type","input_text"},{"text",text}}}}})});
    }
private slots:
    /// 4 MiB 预算耗尽时单个任务显示同步中；追到文件尾后恢复原待答问题。
    void testSourcePublishesUnknownWhileCatchingUpWithoutLosingItsQuestion() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path,initialQuestion());
        makeDatabase(dir,{"fixture"});
        IsolatedCodexSource source(dir.path());
        QCOMPARE(source.snapshot(instant()).tasks.value(0).activity.phase,TaskPhase::Waiting);
        const int budget = 4*1024*1024;
        const auto burst = QByteArray(budget+1024,'x') + '\n' + lines({call("exec","other",0)});
        append(path,burst);
        const auto behind = source.snapshot(instant());
        QCOMPARE(behind.bytesRead,budget);
        QCOMPARE(behind.tasks.size(),1);
        QCOMPARE(behind.tasks.front().id,QString("fixture"));
        QCOMPARE(behind.tasks.front().activity.phase,TaskPhase::Unknown);
        QCOMPARE(behind.tasks.front().activity.detail,QStringLiteral("正在同步任务活动…"));
        QVERIFY(!behind.warning);
        const auto caught = source.snapshot(instant());
        QCOMPARE(caught.bytesRead,burst.size()-budget);
        QCOMPARE(caught.tasks.value(0).activity.phase,TaskPhase::Waiting);
        append(path,lines({recordEvent("item_completed",0,{{"item",QJsonObject{{"type","UserMessage"}}}})}));
        QCOMPARE(source.snapshot(instant()).tasks.value(0).activity.phase,TaskPhase::Running);
        QCOMPARE(source.snapshot(instant()).bytesRead,0);
    }
    /// 只为指定根任务及其全部后代补时间，并把回查流量纳入快照字节数。
    void testSourceRecoversOnlySelectedRootAndItsDescendants() {
        QTemporaryDir dir;
        const QStringList ids{"root","child","grandchild","unselected"};
        for (int i=0; i<ids.size(); ++i)
            overwrite(dir.filePath(ids[i]+".jsonl"),contents({startTurn(ids[i],i)},
                       {response("function_call",30,{{"name","work"}})},70000));
        makeDatabase(dir,ids,true);
        IsolatedCodexSource source(dir.path());
        const auto cold = source.snapshot(instant(40));
        QCOMPARE(cold.tasks.size(),4);
        for (const auto &task : cold.tasks) QVERIFY(!task.activity.startedAt);
        const auto selected = source.snapshot(instant(40),{"root"});
        QVERIFY(selected.bytesRead > 0);
        QCOMPARE(selected.tasks.size(),4);
        for (const auto &task : selected.tasks) {
            const int i = ids.indexOf(task.id);
            QVERIFY(i >= 0);
            if (i < 3) QCOMPARE(task.activity.startedAt,instant(i));
            else QVERIFY(!task.activity.startedAt);
        }
        QCOMPARE(source.snapshot(instant(40),{"root"}).bytesRead,0);
    }
    /// 等待 20 分钟、2 小时或一天后，三类正式回复都应立即续跑。
    void testLongIdleSnapshotsDoNotPreventAnySupportedUserReplyFromClearingWait() {
        for (int delay : {1200,7200,86400}) {
            const QList<QByteArray> replies{reply("first",delay),lines({recordEvent("user_message",delay)}),
                lines({recordEvent("item_completed",delay,{{"item",QJsonObject{{"type","UserMessage"}}}})})};
            for (const auto &answer : replies) {
                QTemporaryDir dir;
                makeWaiting(dir);
                IsolatedCodexSource source(dir.path());
                QCOMPARE(source.snapshot(instant(10)).tasks.value(0).activity.phase,TaskPhase::Waiting);
                for (int elapsed : {delay/2,delay-1}) {
                    const auto idle = source.snapshot(instant(elapsed));
                    QCOMPARE(idle.bytesRead,0);
                    QCOMPARE(idle.tasks.value(0).activity.phase,TaskPhase::Waiting);
                    QCOMPARE(idle.tasks.value(0).activity.waitingElapsedSeconds(),10);
                }
                append(dir.filePath("rollout.jsonl"),answer);
                const auto resumed = source.snapshot(instant(delay));
                const auto activity = resumed.tasks.value(0).activity;
                QCOMPARE(resumed.bytesRead,answer.size());
                QCOMPARE(activity.phase,TaskPhase::Running);
                QCOMPARE(activity.startedAt,instant());
                QCOMPARE(activity.turnID,QString("current"));
                QCOMPARE(activity.lastEventAt,instant(delay));
                QVERIFY(!activity.waitingStartedAt);
            }
        }
    }
    /// 晚到的回答位于超长工具输出之后，第二次追读后立即解除等待。
    void testLongWaitReplyBehindReadBudgetClearsAsSoonAsSourceCatchesUp() {
        QTemporaryDir dir;
        makeWaiting(dir);
        IsolatedCodexSource source(dir.path());
        source.snapshot(instant(10));
        const int budget = 4*1024*1024;
        const auto burst = lines({response("function_call_output",7199,{{"call_id","ordinary-tool"},{"output",QString(budget,'x')}})}) + reply("first",7200);
        append(dir.filePath("rollout.jsonl"),burst);
        const auto behind = source.snapshot(instant(7200));
        QCOMPARE(behind.bytesRead,budget);
        QCOMPARE(behind.tasks.value(0).activity.phase,TaskPhase::Unknown);
        QCOMPARE(behind.tasks.value(0).activity.detail,QStringLiteral("正在同步任务活动…"));
        const auto caught = source.snapshot(instant(7201));
        QCOMPARE(caught.bytesRead,burst.size()-budget);
        QCOMPARE(caught.tasks.value(0).activity.phase,TaskPhase::Running);
        QCOMPARE(caught.tasks.value(0).activity.turnID,QString("current"));
        QVERIFY(!caught.tasks.value(0).activity.waitingStartedAt);
    }
    /// 同一刷新间隔内先回答再新提问，只显示第二个问题的等待。
    void testFreshQuestionAfterDelayedReplyUsesItsOwnWaitAndClearsIndependently() {
        QTemporaryDir dir;
        makeWaiting(dir);
        IsolatedCodexSource source(dir.path());
        source.snapshot(instant(10));
        const auto path = dir.filePath("rollout.jsonl");
        append(path,reply("first",7200)+lines({call("request_user_input_async","second",7209)}));
        const auto renewed = source.snapshot(instant(7210));
        QCOMPARE(renewed.tasks.value(0).activity.phase,TaskPhase::Waiting);
        QCOMPARE(renewed.tasks.value(0).activity.waitingElapsedSeconds(),7209);
        append(path,reply("second",7255));
        const auto resumed = source.snapshot(instant(7255));
        QCOMPARE(resumed.tasks.value(0).activity.phase,TaskPhase::Running);
        QVERIFY(!resumed.tasks.value(0).activity.waitingStartedAt);
        append(path,lines({output("second",7256),recordEvent("task_complete",7257,{{"turn_id","current"}})}));
        QCOMPARE(source.snapshot(instant(7258)).tasks.value(0).activity.phase,TaskPhase::Completed);
    }
};
QTEST_GUILESS_MAIN(RolloutSourceContinuationTests)
#include "test_rollout_source_continuation.moc"
