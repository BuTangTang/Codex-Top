#include "claude/claude_transcript_reducer.h"
#include "codex/rollout_reducer.h"
#include "policy/monitoring_policy.h"
#include <QFile>
#include <QJsonDocument>
#include <QTimeZone>
#include <QtTest>

using namespace codextop;
namespace {
QJsonValue seconds(const std::optional<PreciseTimestamp> &date) {
    return date ? QJsonValue(date->referenceSeconds()) : QJsonValue(QJsonValue::Null);
}
bool keepsAutomaticSelection(const TaskActivity &activity, TaskOrigin origin) {
    const auto now = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
    CodexTask task;
    task.id = "fixture";
    task.origin = origin;
    task.title = QStringLiteral("合成任务");
    task.project = "synthetic";
    task.createdAt = task.updatedAt = now;
    task.rolloutPath = "/synthetic.jsonl";
    task.activity = activity;
    MonitorPreferences p;
    p.initialized = true;
    p.autoMonitor = false;
    p.finishedRetentionDays = 0;
    p.selectedIDs = {task.id};
    MonitoringPolicy::reconcile(p, {task}, now);
    return p.selectedIDs.contains(task.id);
}
QJsonObject snapshot(const TaskActivity &a, TaskOrigin origin, const PreciseTimestamp &later) {
    const auto elapsed = a.waitingElapsedSeconds();
    const auto effective = a.effective(later.date, 900, originDisplayName(origin));
    return {{"phase", phaseRawValue(a.phase)}, {"label", phaseLabel(a.phase)}, {"detail", a.detail},
            {"lastEventAt", seconds(a.lastEventTimestamp())}, {"startedAt", seconds(a.startedTimestamp())},
            {"waitingStartedAt", seconds(a.waitingStartedTimestamp())},
            {"turnID", a.turnID ? QJsonValue(*a.turnID) : QJsonValue(QJsonValue::Null)},
            {"waitingElapsedSeconds", elapsed ? QJsonValue(*elapsed) : QJsonValue(QJsonValue::Null)},
            {"keepsAutomaticSelection", keepsAutomaticSelection(a, origin)},
            {"effectiveAtReferenceSeconds", later.referenceSeconds()},
            {"effectivePhase", phaseRawValue(effective.phase)}, {"effectiveDetail", effective.detail}};
}
}

class NativeFixturesTests : public QObject {
    Q_OBJECT
private slots:
    void testActivityMatchesNativeAfterEveryRecord_data() {
        QTest::addColumn<QString>("name");
        QTest::addColumn<bool>("isClaude");
        QTest::newRow("Codex lifecycle") << QString("codex-lifecycle") << false;
        QTest::newRow("Codex TeamChat import and local continuation") << QString("codex-teamchat") << false;
        QTest::newRow("Claude lifecycle") << QString("claude-lifecycle") << true;
        QTest::newRow("Claude desktop closing question") << QString("claude-desktop-question") << true;
    }

    void testActivityMatchesNativeAfterEveryRecord() {
        QFETCH(QString, name);
        QFETCH(bool, isClaude);
        const QString base = "../fixtures/" + name;
        QFile input(QFINDTESTDATA(base + ".input.jsonl"));
        QFile expected(QFINDTESTDATA(base + ".expected.jsonl"));
        QVERIFY2(input.open(QIODevice::ReadOnly), qPrintable(input.errorString()));
        QVERIFY2(expected.open(QIODevice::ReadOnly), qPrintable(expected.errorString()));
        RolloutReducer codex;
        ClaudeTranscriptReducer claude;
        int lineNumber = 0;
        while (!input.atEnd()) {
            ++lineNumber;
            const auto line = input.readLine();
            QVERIFY(!expected.atEnd());
            QJsonParseError error;
            const auto oracle = QJsonDocument::fromJson(expected.readLine(), &error);
            QVERIFY2(oracle.isObject(), qPrintable(error.errorString()));
            const auto native = oracle.object();
            QVERIFY(native.value("effectiveAtReferenceSeconds").isDouble());
            const auto later = PreciseTimestamp::fromReferenceSeconds(native.value("effectiveAtReferenceSeconds").toDouble());
            QVERIFY(later);
            if (isClaude)
                claude.consume(line);
            else
                codex.consume(line);
            const auto actual = snapshot(isClaude ? claude.activity : codex.activity,
                                         isClaude ? TaskOrigin::ClaudeCode : TaskOrigin::Codex, *later);
            const auto message = QStringLiteral("%1 line %2: expected %3; got %4").arg(name).arg(lineNumber)
                .arg(QString::fromUtf8(oracle.toJson(QJsonDocument::Compact)),
                     QString::fromUtf8(QJsonDocument(actual).toJson(QJsonDocument::Compact)));
            // 三个 Date 锚点逐一精确比较；毫秒舍入或宽松浮点比较会掩盖旧事件误接收。
            for (const auto field : {"lastEventAt", "startedAt", "waitingStartedAt"}) {
                if (native.value(field).isDouble())
                    QVERIFY2(actual.value(field).isDouble() && actual.value(field).toDouble() == native.value(field).toDouble(),
                             qPrintable(message));
            }
            QVERIFY2(actual == native, qPrintable(message));
        }
        QVERIFY(lineNumber > 0);
        QVERIFY(expected.atEnd());
    }
};

QTEST_APPLESS_MAIN(NativeFixturesTests)
#include "test_native_fixtures.moc"
