#include "codex/rollout_reducer.h"
#include "codex/question_reply_receipt.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTest>

using namespace codextop;

class TimestampPrecisionTests : public QObject {
    Q_OBJECT
    static QByteArray event(const QString &type, const QString &time) {
        return QJsonDocument(QJsonObject{{"type","event_msg"}, {"timestamp",time},
            {"payload",QJsonObject{{"type",type},{"turn_id","synthetic-turn"}}}}).toJson(QJsonDocument::Compact);
    }

private slots:
    void rejectsEarlierTerminalWithinTheStartMillisecond() {
        RolloutReducer reducer;
        reducer.consume(event("task_started", "2026-11-11T09:00:00.123999Z"));
        const auto original = reducer.activity;
        reducer.consume(event("turn_failed", "2026-11-11T09:00:00.123001Z"));
        QCOMPARE(reducer.activity, original);
        QCOMPARE(reducer.activity.phase, TaskPhase::Running);
        QVERIFY(reducer.activity.startedTimestamp()->referenceSeconds() == 816080400.123999);
    }

    void fractionalIntervalAcrossSecondBoundaryIsStillZeroSeconds() {
        RolloutReducer reducer;
        reducer.consume(event("task_started", "2026-11-11T09:00:00.123999Z"));
        reducer.consume(event("request_user_input", "2026-11-11T09:00:01.123001Z"));
        QCOMPARE(reducer.activity.phase, TaskPhase::Waiting);
        QCOMPARE(reducer.activity.waitingElapsedSeconds(), std::optional<qint64>(0));
        QVERIFY(reducer.activity.waitingStartedTimestamp()->referenceSeconds() == 816080401.123001);
    }

    void timestampsWithoutZoneDoNotSupplyAnAnchor() {
        RolloutReducer reducer;
        reducer.consume(event("task_started", "2026-11-11T09:00:00.123999"));
        QCOMPARE(reducer.activity.phase, TaskPhase::Running);
        QVERIFY(!reducer.activity.startedTimestamp());
        QVERIFY(!reducer.activity.lastEventTimestamp());
        QVERIFY(!parsePreciseTimestamp("2026-11-11T09:00:00.123999"));
    }

    void nanosecondsIndistinguishableInFoundationDateStayEqual() {
        RolloutReducer reducer;
        reducer.consume(event("task_started", "2026-11-11T09:00:00.123000002Z"));
        reducer.consume(event("turn_aborted", "2026-11-11T09:00:00.123000001Z"));
        QCOMPARE(reducer.activity.phase, TaskPhase::Stopped);
    }

    void decimalMillisecondsOnlyAcknowledgeAReplyAfterItsOwnQuestion() {
        const QString thread = "00000000-0000-4000-8000-000000000001";
        const QString turn = "00000000-0000-4000-8000-000000000002";
        const QString client = "00000000-0000-4000-8000-000000000003";
        RolloutReducer reducer;
        reducer.consume(QJsonDocument(QJsonObject{{"type","event_msg"}, {"timestamp","2027-01-15T08:00:00Z"},
            {"payload",QJsonObject{{"type","task_started"},{"turn_id",turn}}}}).toJson(QJsonDocument::Compact));
        reducer.consume(QJsonDocument(QJsonObject{{"type","response_item"}, {"timestamp","2027-01-15T08:00:00.123500Z"},
            {"payload",QJsonObject{{"type","function_call"},{"name","request_user_input_async"},
                                   {"call_id","call_example"},{"arguments",R"({"questions":[{}]})"}}}}).toJson(QJsonDocument::Compact));
        const auto itemID = QJsonDocument(QJsonArray{"request_user_input_async","call_example",0}).toJson(QJsonDocument::Compact);
        const auto body = QJsonDocument(QJsonArray{QJsonObject{{"questionItemId",QString::fromUtf8(itemID)},{"answer","合成"}}})
                              .toJson(QJsonDocument::Compact);
        const QString envelope = "<send_user_message_question_reply>" + QString::fromUtf8(body) + "</send_user_message_question_reply>";
        const auto before = QuestionReplyReceipt::parse(envelope,thread,turn,client,1800000000123.25);
        const auto after = QuestionReplyReceipt::parse(envelope,thread,turn,client,1800000000123.75);
        QVERIFY(before && after);
        const auto now = *parseTimestamp("2027-01-15T08:00:01Z");
        QCOMPARE(reducer.activityAcknowledging({*before},thread,now).phase,TaskPhase::Waiting);
        QCOMPARE(reducer.activityAcknowledging({*after},thread,now).phase,TaskPhase::Running);
    }

    void fractionalDigitsWhichRoundIntoNextSecondUseThatMillisecond() {
        const auto justBefore = parsePreciseTimestamp("2026-11-11T09:00:00.999999999Z");
        const auto whole = parsePreciseTimestamp("2026-11-11T09:00:01Z");
        QVERIFY(justBefore && whole);
        QCOMPARE(justBefore->date,whole->date);
        QVERIFY(justBefore->referenceSeconds() == whole->referenceSeconds());
    }

    void referenceSecondsRoundTripPreservesNativePrecisionAndWholeMilliseconds() {
        for (const char *text : {"2026-11-11T09:00:00.123999Z", "2026-11-11T09:00:01.123001Z",
                                 "2026-11-11T09:00:00.123Z", "1968-12-31T23:59:59.789123Z",
                                 "2001-01-01T00:00:00.000000001Z"}) {
            const auto parsed = parsePreciseTimestamp(text);
            QVERIFY(parsed);
            const auto restored = PreciseTimestamp::fromReferenceSeconds(parsed->referenceSeconds());
            QVERIFY(restored);
            QVERIFY(restored->referenceSeconds() == parsed->referenceSeconds());
            QCOMPARE(restored->date, parsed->date);
        }
    }
};

QTEST_APPLESS_MAIN(TimestampPrecisionTests)
#include "test_timestamp_precision.moc"
