#include "rollout_test_support.h"
using namespace rolloutFixture;

class ReplyContinuationTests : public QObject {
    Q_OBJECT
    /// 准备尚待正式用户回复的异步提问。
    static RolloutReducer beginAsyncWait() {
        RolloutReducer r;
        r.consume(startTurn("current"));
        r.consume(call("request_user_input_async", "async-question", 10));
        return r;
    }
private slots:
    /// 第一条用户消息即可清除异步等待，且保留原轮开始时刻。
    void testResponseUserMessageResumesAsyncWaitBeforeUserMessageEvent() {
        auto r = beginAsyncWait();
        r.consume(output("async-question", 11));
        r.consume(recordEvent("task_complete", 12, {{"turn_id","current"}}));
        QCOMPARE(r.activity.phase, TaskPhase::Waiting);
        QCOMPARE(r.activity.waitingStartedAt, instant(10));
        r.consume(response("message", 20, {{"role","user"}}));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
        QCOMPARE(r.activity.startedAt, instant());
        QCOMPARE(r.activity.turnID, QString("current"));
        QCOMPARE(r.activity.lastEventAt, instant(20));
        QVERIFY(!r.activity.waitingStartedAt && !r.activity.waitingElapsedSeconds());
        r.consume(recordEvent("task_complete", 30, {{"turn_id","current"}}));
        QCOMPARE(r.activity.phase, TaskPhase::Completed);
    }
    /// 非用户角色、普通工具及异步工具自身返回都不能解除等待。
    void testNonUserMessagesAndOrdinaryToolReturnsPreserveAsyncWait() {
        auto r = beginAsyncWait();
        int index = 0;
        for (const QString &role : QStringList{"assistant","developer","tool","system",""}) {
            r.consume(response("message", 20 + index++, role.isEmpty() ? QJsonObject{} : QJsonObject{{"role",role}}));
            QCOMPARE(r.activity.phase, TaskPhase::Waiting);
            QCOMPARE(r.activity.waitingStartedAt, instant(10));
        }
        r.consume(call("ordinary_tool", "other", 30));
        for (const QString &id : QStringList{"other","async-question"}) {
            r.consume(output(id, id == "other" ? 31 : 32));
            QCOMPARE(r.activity.phase, TaskPhase::Waiting);
            QCOMPARE(r.activity.waitingElapsedSeconds(), 10);
        }
    }
    /// 正式回复清掉旧轮所有同步与异步提问编号。
    void testResponseUserMessageClearsOutstandingQuestionIDs() {
        auto r = beginAsyncWait();
        r.consume(call("request_user_input", "old-one", 11));
        r.consume(call("request_user_input", "old-two", 12));
        r.consume(response("message", 20, {{"role","user"}}));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
        r.consume(call("request_user_input", "new-question", 30));
        QCOMPARE(r.activity.waitingElapsedSeconds(), 30);
        r.consume(output("new-question", 40));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
        QVERIFY(!r.activity.waitingStartedAt);
    }
    /// 已终止轮次仅接受晚于终止记录的正式用户消息。
    void testResponseUserMessageResumesTerminalStateButRejectsHistoricalMessage() {
        for (const auto &[type, phase] : QList<std::pair<QString,TaskPhase>>{
                {"task_failed",TaskPhase::Failed},{"task_complete",TaskPhase::Completed},{"turn_aborted",TaskPhase::Stopped}}) {
            RolloutReducer r;
            r.consume(startTurn("old-turn"));
            r.consume(recordEvent(type, 10, {{"turn_id","old-turn"}}));
            r.consume(response("message", 5, {{"role","user"}}));
            QCOMPARE(r.activity.phase, phase);
            QCOMPARE(r.activity.lastEventAt, instant(10));
            r.consume(response("message", 20, {{"role","user"}}));
            QCOMPARE(r.activity.phase, TaskPhase::Running);
            QCOMPARE(r.activity.startedAt, instant(20));
            QVERIFY(!r.activity.turnID && !r.activity.waitingStartedAt);
        }
    }
    /// 缺换行的回复保持等待，补上换行才生效。
    void testIncrementalReplyResumesOnItsFirstCompletedLine() {
        QTemporaryDir dir;
        const auto file = dir.filePath("rollout.jsonl");
        overwrite(file, initialQuestion(10));
        IncrementalRollout reader;
        reader.refresh(file);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Waiting);
        append(file, response("message", 20, {{"role","user"}}));
        reader.refresh(file);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Waiting);
        append(file, "\n");
        QCOMPARE(reader.refresh(file), 1);
        QVERIFY(reader.isCaughtUp);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Running);
        QCOMPARE(reader.reducer.activity.startedAt, instant());
        QCOMPARE(reader.reducer.activity.turnID, QString("current"));
        QVERIFY(!reader.reducer.activity.waitingStartedAt);
        QCOMPARE(reader.refresh(file), 0);
    }
};
QTEST_GUILESS_MAIN(ReplyContinuationTests)
#include "test_reply_continuation.moc"
