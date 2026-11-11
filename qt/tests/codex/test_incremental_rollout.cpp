#include "rollout_test_support.h"
using namespace rolloutFixture;

class IncrementalRolloutTests : public QObject {
    Q_OBJECT
    /// 构造超过单次冷读窗口的 90 对工具调用和返回。
    static QByteArray outputBurst() {
        QByteArray result;
        for (int i = 0; i < 90; ++i) {
            const auto id = QString("other-%1").arg(i);
            result += lines({call("exec", id, 0), response("function_call_output", 0, {{"call_id",id},{"output",QString(1500,'x')}})});
        }
        return result;
    }
private slots:
    /// 已热读时须按顺序读完新增记录，普通输出和额度不能误清等待。
    void testWarmOutputBurstPreservesAsyncQuestionUntilUserReply() {
        QTemporaryDir dir;
        auto path = dir.filePath("rollout.jsonl");
        overwrite(path, initialQuestion());
        IncrementalRollout tail;
        tail.refresh(path);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Waiting);
        const auto burst = outputBurst() + lines({output("question", 0), recordEvent("token_count", 0,
            {{"rate_limits",QJsonObject{{"primary",QJsonObject{{"used_percent",20.0},{"window_minutes",300}}}}}})});
        QVERIFY(burst.size() > 65536);
        append(path, burst);
        QCOMPARE(tail.refresh(path), burst.size());
        QVERIFY(tail.isCaughtUp);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Waiting);
        QCOMPARE(tail.reducer.activity.turnID, QString("current"));
        QVERIFY(tail.reducer.quota && tail.reducer.quota->fiveHour());
        QCOMPARE(tail.reducer.quota->fiveHour()->remainingPercent(), 80);
        append(path, lines({recordEvent("item_completed", 0, {{"item",QJsonObject{{"type","UserMessage"}}}})}));
        tail.refresh(path);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Running);
        QCOMPARE(tail.refresh(path), 0);
    }
    /// 大量输出之后到达的旧轮结束仍然不影响当前轮次。
    void testWarmOutputBurstPreservesTurnIDAgainstOldCompletion() {
        QTemporaryDir dir;
        auto path = dir.filePath("rollout.jsonl");
        overwrite(path, lines({startTurn("current")}));
        IncrementalRollout tail;
        tail.refresh(path);
        const auto burst = outputBurst() + lines({recordEvent("task_complete", 0, {{"turn_id","old"}})});
        append(path, burst);
        QCOMPARE(tail.refresh(path), burst.size());
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Running);
        QCOMPARE(tail.reducer.activity.turnID, QString("current"));
    }
    /// 追读预算截断时保存顺序，末尾半行只在补齐换行后生效。
    void testCatchUpBudgetKeepsOrderAndDoesNotParseAnUnfinishedLine() {
        QTemporaryDir dir;
        auto path = dir.filePath("rollout.jsonl");
        overwrite(path, lines({startTurn("first")}));
        IncrementalRollout tail(1024, 2048);
        tail.refresh(path);
        const auto completion = recordEvent("task_complete", 0, {{"turn_id","second"}});
        const auto split = completion.size() / 2;
        const auto rest = lines({startTurn("second")}) + completion.left(split);
        append(path, QByteArray(2047, ' ') + '\n' + rest);
        QCOMPARE(tail.refresh(path), 2048);
        QVERIFY(!tail.isCaughtUp);
        QCOMPARE(tail.reducer.activity.turnID, QString("first"));
        QCOMPARE(tail.refresh(path), rest.size());
        QVERIFY(tail.isCaughtUp);
        QCOMPARE(tail.reducer.activity.turnID, QString("second"));
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Running);
        append(path, completion.mid(split) + '\n');
        tail.refresh(path);
        QCOMPARE(tail.reducer.activity.phase, TaskPhase::Completed);
        QCOMPARE(tail.refresh(path), 0);
    }
    /// 同一文件在追读中被等长或缩短重写时，依据采样长度丢弃旧状态。
    void testRewriteDuringCatchUpUsesObservedSizeInsteadOfCursor() {
        for (bool shrink : {false,true}) {
            QTemporaryDir dir;
            auto path = dir.filePath("rollout.jsonl");
            const auto initial = initialQuestion(), burst = QByteArray(4096, 'x') + '\n';
            overwrite(path, initial);
            setModified(path, instant());
            IncrementalRollout tail(1024, 2048);
            tail.refresh(path);
            append(path, burst);
            setModified(path, instant(1));
            tail.refresh(path);
            QVERIFY(!tail.isCaughtUp);
            QCOMPARE(tail.reducer.activity.phase, TaskPhase::Waiting);
            const auto newSize = initial.size() + burst.size() - (shrink ? 512 : 0);
            QVERIFY(newSize > tail.offset);
            const auto completion = lines({recordEvent("task_complete", 0, {{"turn_id","replacement"}})});
            overwrite(path, QByteArray(newSize - completion.size() - 1, 'x') + '\n' + completion);
            setModified(path, instant(2));
            QVERIFY(tail.refresh(path) <= 1024);
            QVERIFY(tail.isCaughtUp);
            QCOMPARE(tail.reducer.activity.phase, TaskPhase::Completed);
            QCOMPARE(tail.refresh(path), 0);
        }
    }
};
QTEST_GUILESS_MAIN(IncrementalRolloutTests)
#include "test_incremental_rollout.moc"
