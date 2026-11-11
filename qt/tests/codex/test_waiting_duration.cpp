#include "rollout_test_support.h"
using namespace rolloutFixture;

class WaitingDurationTests : public QObject {
    Q_OBJECT
    struct Record { QString kind, type; QJsonObject extra; };
private slots:
    /// 所有等待入口在额度、普通工具和重复提问后仍保留第一次等待时刻。
    void testAllRecognizedWaitEntriesKeepTheirFirstTimestampAcrossMetadata() {
        const QList<Record> entries{
            {"event_msg","request_user_input",{}},{"event_msg","user_input_requested",{}},
            {"event_msg","exec_approval_request",{}},{"event_msg","apply_patch_approval_request",{}},
            {"response_item","function_call",{{"name","request_user_input"},{"call_id","question"}}},
            {"response_item","custom_tool_call",{{"name","request_user_input_async"},{"call_id","question"}}},
            {"response_item","function_call",{{"name","tools__request_user_input"},{"call_id","question"}}}
        };
        for (const auto &[kind, type, extra] : entries) {
            RolloutReducer r;
            r.consume(startTurn("current"));
            r.consume(recordEvent(type, 12, extra, kind));
            r.consume(output("ordinary-output", 20));
            r.consume(response("function_call", 25, {{"name","account_usage_read"}}));
            r.consume(recordEvent("token_count", 30, {{"rate_limits",QJsonObject{{"primary",QJsonObject{{"used_percent",20.0},{"window_minutes",300}}}}}}));
            r.consume(recordEvent("agent_message", 35));
            r.consume(recordEvent(type, 40, extra, kind));
            QCOMPARE(r.activity.phase, TaskPhase::Waiting);
            QCOMPARE(r.activity.waitingStartedAt, instant(12));
            QCOMPARE(r.activity.waitingElapsedSeconds(), 12);
            QCOMPARE(r.activity.lastEventAt, instant(40));
            QCOMPARE(r.activity.effective(instant(10000)).waitingElapsedSeconds(), 12);
        }
    }
    /// 用户回答清除等待锚点，下一次等待从同一轮开始时刻计量。
    void testAnswerClearsAnchorAndAnotherWaitMeasuresFromTheSameTurnStart() {
        const QList<Record> replies{
            {"event_msg","user_message",{}},{"event_msg","user_input",{}},{"event_msg","approval_resolved",{}},
            {"event_msg","item_completed",{{"item", QJsonObject{{"type","userMessage"}}}}},
            {"response_item","function_call_output",{{"call_id","question"}}}
        };
        for (const auto &[kind, type, extra] : replies) {
            RolloutReducer r;
            r.consume(startTurn("first"));
            r.consume(call("request_user_input", "question", 12));
            r.consume(recordEvent(type, 50, extra, kind));
            QCOMPARE(r.activity.phase, TaskPhase::Running);
            QVERIFY(!r.activity.waitingStartedAt && !r.activity.waitingElapsedSeconds());
            r.consume(recordEvent("exec_approval_request", 70));
            QCOMPARE(r.activity.waitingElapsedSeconds(), 70);
            r.consume(recordEvent("turn_started", 100, {{"turn_id","second"}}));
            QVERIFY(!r.activity.waitingStartedAt);
            r.consume(recordEvent("apply_patch_approval_request", 105));
            QCOMPARE(r.activity.waitingElapsedSeconds(), 5);
        }
    }
    /// 多个同步问题必须全部回答；有异步问题时还需正式用户消息。
    void testMultipleQuestionsAndAsyncQuestionDoNotResumeEarly() {
        RolloutReducer r;
        r.consume(recordEvent("task_started"));
        r.consume(call("request_user_input", "one", 10));
        r.consume(call("request_user_input", "two", 20));
        r.consume(output("one", 30));
        QCOMPARE(r.activity.waitingElapsedSeconds(), 10);
        r.consume(output("ordinary", 40));
        QCOMPARE(r.activity.waitingElapsedSeconds(), 10);
        r.consume(output("two", 50));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
        QVERIFY(!r.activity.waitingStartedAt);
        r.consume(call("request_user_input_async", "async", 60));
        r.consume(call("request_user_input", "sync", 70));
        r.consume(output("sync", 80));
        QCOMPARE(r.activity.waitingElapsedSeconds(), 60);
        r.consume(output("async", 90));
        QCOMPARE(r.activity.waitingElapsedSeconds(), 60);
        r.consume(recordEvent("user_message", 100));
        QCOMPARE(r.activity.phase, TaskPhase::Running);
        QVERIFY(!r.activity.waitingStartedAt);
    }
    /// 异步问题后即使追加多种结束消息也保留原等待时刻。
    void testAsyncCompletionPreservesTheWaitAnchor() {
        RolloutReducer r;
        r.consume(startTurn("current"));
        r.consume(call("request_user_input_async", "question", 15));
        int seconds = 30;
        for (const QString &type : QStringList{"task_complete","turn_complete"}) {
            r.consume(recordEvent(type, seconds++, {{"turn_id","current"}}));
            QCOMPARE(r.activity.phase, TaskPhase::Waiting);
            QCOMPARE(r.activity.waitingStartedAt, instant(15));
            QCOMPARE(r.activity.waitingElapsedSeconds(), 15);
        }
        r.consume(recordEvent("item_completed", 40, {{"item", QJsonObject{{"type","userMessage"}}}}));
        QVERIFY(!r.activity.waitingStartedAt);
    }
    /// 首次等待无时间时不得从重复等待、收尾或冷读尾部推算。
    void testMissingFirstWaitTimestampCannotBeInventedByARepeatedWaitOrCompletion() {
        RolloutReducer r;
        r.consume(recordEvent("task_started"));
        r.consume(call("request_user_input_async", "question", std::nullopt));
        r.consume(call("request_user_input_async", "question", 20));
        r.consume(recordEvent("task_complete", 30));
        QCOMPARE(r.activity.phase, TaskPhase::Waiting);
        QVERIFY(!r.activity.waitingStartedAt && !r.activity.waitingElapsedSeconds());
        r.consume(recordEvent("user_input", 40));
        r.consume(recordEvent("user_input_requested", 50));
        QCOMPARE(r.activity.waitingElapsedSeconds(), 50);
        RolloutReducer missingStart;
        missingStart.consume(recordEvent("task_started", std::nullopt));
        missingStart.consume(recordEvent("request_user_input", 10));
        QVERIFY(!missingStart.activity.waitingElapsedSeconds());
        RolloutReducer cold;
        cold.consume(recordEvent("exec_approval_request", 10));
        QVERIFY(!cold.activity.startedAt && !cold.activity.waitingElapsedSeconds());
    }
    /// 所有终止事件均按轮次匹配，旧轮终止不打断当前等待。
    void testCurrentTerminalsClearAnchorAndOldTerminalsCannotClearIt() {
        for (const QString &type : QStringList{"task_complete","turn_complete","turn_aborted","task_cancelled","turn_cancelled","task_failed","turn_failed"}) {
            RolloutReducer r;
            r.consume(startTurn("current"));
            r.consume(recordEvent("request_user_input", 10));
            r.consume(recordEvent(type, 20, {{"turn_id","old"}}));
            QCOMPARE(r.activity.waitingElapsedSeconds(), 10);
            r.consume(recordEvent(type, 30, {{"turn_id","current"}}));
            QVERIFY(r.activity.phase != TaskPhase::Waiting);
            QVERIFY(!r.activity.waitingStartedAt && !r.activity.waitingElapsedSeconds());
        }
    }
    /// 结束后出现的新等待不借用上轮开始锚点。
    void testWaitAfterCompletedTurnDoesNotReuseItsOldStart() {
        RolloutReducer r;
        r.consume(startTurn("previous"));
        r.consume(recordEvent("task_complete", 10, {{"turn_id","previous"}}));
        r.consume(recordEvent("exec_approval_request", 20));
        QCOMPARE(r.activity.phase, TaskPhase::Waiting);
        QVERIFY(!r.activity.startedAt && !r.activity.turnID && !r.activity.waitingElapsedSeconds());
    }
    /// 非等待、锚点缺失、无效及倒序都不显示时长；秒数向下取整。
    void testDurationRequiresFiniteOrderedAnchorsAndAWaitingPhase() {
        TaskActivity a;
        a.phase = TaskPhase::Waiting;
        a.startedAt = instant();
        QVERIFY(!a.waitingElapsedSeconds());
        a.startedAt.reset(); a.waitingStartedAt = instant();
        QVERIFY(!a.waitingElapsedSeconds());
        a.startedAt = instant(); a.waitingStartedAt = instant(-1);
        QVERIFY(!a.waitingElapsedSeconds());
        // Qt 的时间类型没有 NaN、无穷或 1e30 秒，均以不可表示的无效时间传入。
        a.waitingStartedAt = QDateTime{};
        QVERIFY(!a.waitingElapsedSeconds());
        a.startedAt = QDateTime{}; a.waitingStartedAt = instant();
        QVERIFY(!a.waitingElapsedSeconds());
        a.startedAt = a.waitingStartedAt = instant();
        QCOMPARE(a.waitingElapsedSeconds(), 0);
        a.waitingStartedAt = instant().addMSecs(12900);
        QCOMPARE(a.waitingElapsedSeconds(), 12);
        a.waitingStartedAt = instant(10);
        for (const auto phase : {TaskPhase::Running,TaskPhase::Completed,TaskPhase::Stopped,
                                 TaskPhase::Failed,TaskPhase::Idle,TaskPhase::Unknown}) {
            a.phase = phase;
            QVERIFY(!a.waitingElapsedSeconds());
        }
    }
};
QTEST_GUILESS_MAIN(WaitingDurationTests)
#include "test_waiting_duration.moc"
