#include "claude/claude_transcript_reducer.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QTest>
#include <QTimeZone>
using namespace codextop;

class ClaudeTimestampTests : public QObject {
    Q_OBJECT
    /// 生成独立起始或结束记录。Undefined 省略字段，Null 属于显式无时间。
    static QByteArray record(QJsonValue timestamp, bool completed=false) {
        QJsonObject value{{"type",completed ? "assistant" : "user"}};
        if (!timestamp.isUndefined()) value["timestamp"] = timestamp;
        value["message"] = completed
            ? QJsonObject{{"role","assistant"},{"stop_reason","end_turn"},{"content",QJsonArray{QJsonObject{{"type","text"},{"text","done"}}}}}
            : QJsonObject{{"role","user"},{"content","synthetic"}};
        return QJsonDocument(value).toJson(QJsonDocument::Compact);
    }
private slots:
    /// 整秒、小数秒和正负时区换算到相同的 UTC 绝对时刻。
    void testTimestampVariantsPreserveInstants() {
        const qint64 base=1794187866000;
        const QList<std::pair<QString,qint64>> samples{
            {"2026-11-09T01:31:06Z",base},{"2026-11-09T01:31:06.125Z",base+125},
            {"2026-11-09T09:31:06+08:00",base},{"2026-11-09T09:31:06.125+08:00",base+125},
            {"2026-11-08T20:31:06-05:00",base},{"2026-11-08T20:31:06.5-05:00",base+500}
        };
        for(const auto &[stamp,ms]:samples) {
            ClaudeTranscriptReducer r;
            r.consume(record(stamp));
            QVERIFY(r.activity.startedAt);
            QCOMPARE(r.activity.startedAt->toMSecsSinceEpoch(),ms);
            QCOMPARE(r.activity.lastEventAt,r.activity.startedAt);
            QCOMPARE(r.firstEventAt,r.activity.startedAt);
        }
    }
    /// 缺失、空、非字符串和无效时刻不被补成当前时间；结束行保留之前明确时间。
    void testMissingAndInvalidTimestampKeepExistingSemantics() {
        for (const auto &stamp : QList<QJsonValue>{QJsonValue::Undefined,QJsonValue::Null,"","invalid",42}) {
            ClaudeTranscriptReducer fresh;
            fresh.consume(record(stamp));
            QCOMPARE(fresh.activity.phase,TaskPhase::Running);
            QVERIFY(!fresh.firstEventAt && !fresh.activity.startedAt && !fresh.activity.lastEventAt);
            ClaudeTranscriptReducer started;
            started.consume(record("2026-11-09T01:31:06.125Z"));
            auto known=started.activity.lastEventAt;
            started.consume(record(stamp,true));
            QCOMPARE(started.activity.phase,TaskPhase::Completed);
            QCOMPARE(started.activity.startedAt,known);
            QCOMPARE(started.activity.lastEventAt,known);
            QCOMPARE(started.firstEventAt,known);
        }
    }
    /// 跨时区旧行不重开任务，新的合法输入可开始下一轮。
    void testOlderOffsetTimestampCannotReopenCompletedTurn() {
        ClaudeTranscriptReducer r;
        r.consume(record("2026-11-09T01:31:06.125Z"));
        r.consume(record("2026-11-09T09:31:36+08:00",true));
        auto completed=r.activity;
        r.consume(record("2026-11-08T20:31:35.999-05:00"));
        QCOMPARE(r.activity,completed);
        r.consume(record("2026-11-08T20:31:37-05:00"));
        QCOMPARE(r.activity.phase,TaskPhase::Running);
        QVERIFY(r.activity.startedAt);
        QCOMPARE(r.activity.startedAt->toMSecsSinceEpoch(),1794187897000LL);
    }
};
QTEST_GUILESS_MAIN(ClaudeTimestampTests)
#include "test_claude_timestamp.moc"
