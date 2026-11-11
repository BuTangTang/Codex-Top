#include "codex/rollout_reducer.h"
#include "codex/question_reply_receipt.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTest>
#include <QTimeZone>

using namespace codextop;

class QuestionReplyProjectionTests : public QObject {
    Q_OBJECT

    const QDateTime start = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
    const QString thread = "00000000-0000-4000-8000-000000000001";
    const QString turn = "00000000-0000-4000-8000-000000000002";

    QByteArray event(const QString &type, int seconds, const QString &kind = "event_msg", QJsonObject extra = {}) const
    {
        extra.insert("type",type);
        return QJsonDocument(QJsonObject{{"timestamp",start.addSecs(seconds).toString(Qt::ISODate)},
                                         {"type",kind},{"payload",extra}}).toJson(QJsonDocument::Compact);
    }

    void ask(RolloutReducer &r, const QString &call, int count, int seconds) const
    {
        QJsonArray questions;
        for (int i = 0; i < count; ++i)
            questions.append(QJsonObject{{"title","合成问题 " + QString::number(i)}});
        const auto args = QJsonDocument(QJsonObject{{"questions",questions}}).toJson(QJsonDocument::Compact);
        r.consume(event("function_call",seconds,"response_item",
                        {{"name","request_user_input_async"},{"call_id",call},{"arguments",QString::fromUtf8(args)}}));
    }

    RolloutReducer asking(int count = 1) const
    {
        RolloutReducer r;
        r.consume(event("task_started",0,"event_msg",{{"turn_id",turn}}));
        ask(r,"call_first",count,10);
        return r;
    }

    QuestionReplyReceipt receipt(QString call = "call_first", QSet<int> items = {0}, int seconds = 20) const
    {
        return {thread,turn,"00000000-0000-4000-8000-000000000003",start.addSecs(seconds),{{call,items}}};
    }

private slots:
    void testReceiptProjectsReplyBeforeDelayedHistoryWithoutMutatingReducer()
    {
        const auto r = asking();
        const auto original = r.activity;
        const auto shown = r.activityAcknowledging({receipt()},thread,start.addSecs(21));
        QCOMPARE(shown.phase,TaskPhase::Running);
        QCOMPARE(shown.detail,"已回复，等待继续");
        QVERIFY(!shown.waitingStartedAt);
        QCOMPARE(shown.startedAt,original.startedAt);
        QCOMPARE(shown.lastEventAt,original.lastEventAt);
        QCOMPARE(shown.turnID,original.turnID);
        QCOMPARE(r.activity,original);
    }

    void testMismatchedAndImpossibleReceiptsKeepWaiting()
    {
        const auto r = asking();
        auto wrongThread = receipt(); wrongThread.threadID = "other";
        auto wrongTurn = receipt(); wrongTurn.turnID = "other";
        for (const auto &item : {wrongThread,wrongTurn,receipt("call_other"),receipt("call_first",{1}),
                                 receipt("call_first",{0},9),receipt("call_first",{0},100)})
            QCOMPARE(r.activityAcknowledging({item},thread,start.addSecs(21)).phase,TaskPhase::Waiting);
    }

    void testPartialAndDuplicateAnswersDoNotClearOtherItems()
    {
        const auto r = asking(2);
        QCOMPARE(r.activityAcknowledging({receipt(),receipt()},thread,start.addSecs(21)).phase,TaskPhase::Waiting);
        QCOMPARE(r.activityAcknowledging({receipt(),receipt("call_first",{1})},thread,start.addSecs(21)).phase,TaskPhase::Running);
    }

    void testNewQuestionRequiresItsOwnReply()
    {
        auto r = asking();
        ask(r,"call_second",1,25);
        QCOMPARE(r.activityAcknowledging({receipt()},thread,start.addSecs(40)).phase,TaskPhase::Waiting);
        QCOMPARE(r.activityAcknowledging({receipt(),receipt("call_second",{0},30)},thread,start.addSecs(40)).phase,TaskPhase::Running);
    }

    void testOtherWaitingReasonsCannotBeClearedByAsyncReply()
    {
        for (const char *type : {"exec_approval_request","apply_patch_approval_request","user_input_requested"}) {
            auto r = asking(); r.consume(event(type,15));
            QVERIFY(!r.awaitingReplySince());
            QCOMPARE(r.activityAcknowledging({receipt()},thread,start.addSecs(21)).phase,TaskPhase::Waiting);
        }
        auto r = asking();
        r.consume(event("function_call",15,"response_item",{{"name","request_user_input"},{"call_id","sync"}}));
        QCOMPARE(r.activityAcknowledging({receipt()},thread,start.addSecs(21)).phase,TaskPhase::Waiting);
    }

    void testAuthoritativeEventsWinOverCachedReceipt()
    {
        for (const char *type : {"user_message","turn_aborted","task_failed","task_complete"}) {
            auto r = asking();
            r.consume(event(type,30,"event_msg",{{"turn_id",turn}}));
            QVERIFY(!r.awaitingReplySince());
            QCOMPARE(r.activityAcknowledging({receipt()},thread,start.addSecs(31)),r.activity.effective(start.addSecs(31)));
        }
    }

    void testReceiptFreshnessDoesNotInventExecutionTimestamp()
    {
        const auto r = asking();
        const auto fresh = r.activityAcknowledging({receipt("call_first",{0},2000)},thread,start.addSecs(2001));
        QCOMPARE(fresh.phase,TaskPhase::Running);
        QCOMPARE(fresh.lastEventAt,r.activity.lastEventAt);
        const auto stale = r.activityAcknowledging({receipt()},thread,start.addSecs(1000));
        QCOMPARE(stale.phase,TaskPhase::Unknown);
        QCOMPARE(stale.detail,"已回复，较久未收到后续活动");
    }

    void testMissingQuestionMetadataFailsClosed()
    {
        RolloutReducer r;
        r.consume(event("function_call",10,"response_item",{{"name","request_user_input_async"},{"call_id","call_first"}}));
        QVERIFY(!r.awaitingReplySince());
        QCOMPARE(r.activityAcknowledging({receipt()},thread,start.addSecs(21)).phase,TaskPhase::Waiting);
    }

    void testOldTurnReceiptCannotAffectNewTurn()
    {
        auto r = asking();
        r.consume(event("task_started",25,"event_msg",{{"turn_id","new-turn"}}));
        ask(r,"call_first",1,30);
        QCOMPARE(r.activityAcknowledging({receipt("call_first",{0},35)},thread,start.addSecs(40)).phase,TaskPhase::Waiting);
    }
};
QTEST_GUILESS_MAIN(QuestionReplyProjectionTests)
#include "test_question_reply_projection.moc"
