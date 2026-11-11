#include "rollout_test_support.h"
using namespace rolloutFixture;

class RecoveryTests : public QObject {
    Q_OBJECT
    /// 分 1 KiB 预算持续回查，每一步都核对主读取游标没有变化。
    static void finish(IncrementalRollout &reader, const QString &path, int &total, int budget = 1024) {
        total = 0;
        for (int i = 0; i < 100; ++i) {
            const auto offset = reader.offset;
            const auto bytes = reader.recoverTiming(path,budget);
            QVERIFY(bytes <= budget);
            QCOMPARE(reader.offset, offset);
            total += bytes;
            if (bytes == 0 || reader.reducer.activity.startedAt) return;
        }
        QFAIL("合成时间回查在有界次数内没有结束");
    }
    /// 当前轮中的普通工具记录维持运行状态。
    static QByteArray work(int seconds) { return response("function_call", seconds, {{"name","work"}}); }
private slots:
    /// 回查期间发生的新写入、回复半行与其余待答问题全部保留。
    void testProgressiveRecoveryPreservesNewWritesPartialLineAndOutstandingQuestions() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path, contents({startTurn("current")}, {call("request_user_input","one",20),call("request_user_input","two",21)}));
        IncrementalRollout reader(1024);
        QCOMPARE(reader.refresh(path), 1024);
        QVERIFY(!reader.reducer.activity.startedAt);
        QCOMPARE(reader.recoverTiming(path,1024), 1024);
        QVERIFY(!reader.reducer.activity.startedAt);
        append(path, lines({output("one",30)}) + output("two",40));
        reader.refresh(path);
        const auto last = reader.reducer.activity.lastEventAt;
        int bytes;
        finish(reader,path,bytes);
        QVERIFY(bytes > 1024);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Waiting);
        QCOMPARE(reader.reducer.activity.lastEventAt,last);
        QCOMPARE(reader.reducer.activity.startedAt, instant());
        QCOMPARE(reader.reducer.activity.turnID, QString("current"));
        QCOMPARE(reader.reducer.activity.waitingElapsedSeconds(),20);
        append(path,"\n");
        QCOMPARE(reader.refresh(path),1);
        QCOMPARE(reader.reducer.activity.phase,TaskPhase::Running);
        QVERIFY(!reader.reducer.activity.waitingStartedAt);
    }
    /// 中文提问的异步等待及本轮结束标记在回查后仍需用户正式回答。
    void testAsyncWaitAndTrailingCompletionKeepCurrentStart() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path,contents({startTurn("current")},
            {call("request_user_input_async","question",10),recordEvent("task_complete",20,{{"turn_id","current"}})}));
        IncrementalRollout reader(1024);
        reader.refresh(path);
        int bytes;
        finish(reader,path,bytes);
        QCOMPARE(reader.reducer.activity.phase,TaskPhase::Waiting);
        QCOMPARE(reader.reducer.activity.waitingElapsedSeconds(),10);
        append(path,lines({output("question",30)}));
        reader.refresh(path);
        QCOMPARE(reader.reducer.activity.phase,TaskPhase::Waiting);
    }
    /// 重放分别识别迟到的旧轮终止、正式续接及缺开始的新等待。
    void testReplayDistinguishesOldTerminalUserContinuationAndWaitWithoutNewStart() {
        struct Case { QList<QByteArray> prefix, suffix; std::optional<QDateTime> start; std::optional<QString> turn; };
        const QList<Case> cases{
            {{startTurn("current"),recordEvent("task_complete",10,{{"turn_id","old"}})},{work(30)},instant(),QString("current")},
            {{startTurn("old"),recordEvent("task_failed",10),response("message",20,{{"role","user"}})},{work(30)},instant(20),{}},
            {{startTurn("old"),recordEvent("task_complete",10)},{recordEvent("exec_approval_request",30)},{},{}}
        };
        for (const auto &c : cases) {
            QTemporaryDir dir;
            const auto path = dir.filePath("rollout.jsonl");
            overwrite(path,contents(c.prefix,c.suffix));
            IncrementalRollout reader(1024);
            reader.refresh(path);
            const auto original = reader.reducer.activity;
            int bytes;
            finish(reader,path,bytes);
            QCOMPARE(reader.reducer.activity.startedAt,c.start);
            QCOMPARE(reader.reducer.activity.turnID,c.turn);
            QCOMPARE(reader.reducer.activity.phase,original.phase);
            QCOMPARE(reader.reducer.activity.lastEventAt,original.lastEventAt);
        }
    }
    /// 最近开始记录缺时间，不能越过它借用较老轮次的时间。
    void testNearestStartWithoutTimestampCannotBorrowOlderStart() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path,contents({startTurn("old"),recordEvent("task_complete",10),startTurn("current",std::nullopt)}, {work(30)}));
        IncrementalRollout reader(1024);
        reader.refresh(path);
        int bytes;
        finish(reader,path,bytes);
        QVERIFY(!reader.reducer.activity.startedAt);
        QCOMPARE(reader.recoverTiming(path,1024),0);
    }
    /// 没有开始记录时，后续普通追加保留失败缓存，不反复扫描旧历史。
    void testSearchWithoutStartIsCachedAcrossOrdinaryAppends() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path,contents({}, {work(30)}));
        IncrementalRollout reader(1024);
        reader.refresh(path);
        int bytes;
        finish(reader,path,bytes);
        QVERIFY(!reader.reducer.activity.startedAt);
        for (int second : {40,50}) {
            append(path,lines({work(second)}));
            reader.refresh(path);
            QCOMPARE(reader.recoverTiming(path,1024),0);
        }
    }
    /// 同一路径被替换或原地等长重写，旧回查失败缓存都须失效。
    void testReplacementAndSameSizeRewriteResetCachedFailure() {
        for (bool replace : {true,false}) {
            QTemporaryDir dir;
            const auto path = dir.filePath("rollout.jsonl");
            const auto initial = contents({recordEvent("agent_message")},{work(30)});
            overwrite(path,initial);
            IncrementalRollout reader(1024);
            reader.refresh(path);
            int bytes;
            finish(reader,path,bytes);
            QVERIFY(!reader.reducer.activity.startedAt);
            auto replacement = contents({startTurn("new",10)},{work(30)});
            const auto size = std::max(initial.size(),replacement.size());
            if (initial.size() < size) {
                append(path,QByteArray(size - initial.size(),' '));
                reader.refresh(path);
            }
            replacement = replacement.leftJustified(size,' ');
            if (replace) QVERIFY(QFile::rename(path,dir.filePath("old.jsonl")));
            overwrite(path,replacement);
            if (!replace) setModified(path,QDateTime::currentDateTimeUtc().addSecs(5));
            reader.refresh(path);
            finish(reader,path,bytes);
            QCOMPARE(reader.reducer.activity.startedAt,instant(10));
            QCOMPARE(reader.reducer.activity.turnID,QString("new"));
        }
    }
    /// 新一轮显式开始会立即取消旧轮尚未结束的回查。
    void testNewObservedTurnCancelsInProgressRecovery() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path,contents({startTurn("old")},{work(30)}));
        IncrementalRollout reader(1024);
        reader.refresh(path);
        QCOMPARE(reader.recoverTiming(path,1024),1024);
        append(path,lines({startTurn("new",40)}));
        reader.refresh(path);
        QCOMPARE(reader.recoverTiming(path,1024),0);
        QCOMPARE(reader.reducer.activity.startedAt,instant(40));
        QCOMPARE(reader.reducer.activity.turnID,QString("new"));
    }
};
QTEST_GUILESS_MAIN(RecoveryTests)
#include "test_recovery.moc"
