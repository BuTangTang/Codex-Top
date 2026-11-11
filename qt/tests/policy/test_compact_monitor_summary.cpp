#include "policy/compact_monitor_summary.h"
#include <QTest>
using namespace codextop;
using Phase = TaskPhase;
class CompactMonitorSummaryTests : public QObject {
    Q_OBJECT
    const QDateTime instant = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
    CompactMonitorSummary summary(const QList<Phase> &phases, bool paused = false,
                                  const std::optional<QuotaSnapshot> &quota = {}) {
        return {MonitorStatusSummary(phases), paused, quota, instant};
    }
  private slots:
    void testAttentionOverridesRunningAndPausedWithoutLosingFailureColor() {
        for (const bool paused : {false, true}) {
            auto waiting = summary({Phase::Running, Phase::Running, Phase::Waiting}, paused);
            QCOMPARE(waiting.leftText, "1 待处理");
            QCOMPARE(waiting.leftPhase, Phase::Waiting);
            auto failed = summary({Phase::Running, Phase::Waiting, Phase::Failed}, paused);
            QCOMPARE(failed.leftText, "2 待处理");
            QCOMPARE(failed.leftPhase, Phase::Failed);
        }
    }
    void testPauseReplacesTheRunningCountOnlyWhenNoAttentionIsPending() {
        auto paused = summary({Phase::Running, Phase::Running}, true);
        QCOMPARE(paused.leftText, "已暂停");
        QCOMPARE(paused.leftPhase, Phase::Idle);
        auto active = summary({Phase::Running, Phase::Running, Phase::Completed});
        QCOMPARE(active.leftText, "2 运行中");
        QCOMPARE(active.leftPhase, Phase::Running);
    }
    void testInactiveStatesDistinguishEmptyFromUnstartedAndUnknownTasks() {
        struct Example {
            QList<Phase> phases;
            QString text;
            Phase phase;
        };
        const QList<Example> examples{{{}, "无任务", Phase::Idle},
                                      {{Phase::Idle}, "未运行", Phase::Idle},
                                      {{Phase::Completed, Phase::Completed}, "已完成", Phase::Completed},
                                      {{Phase::Completed, Phase::Unknown}, "状态未知", Phase::Unknown},
                                      {{Phase::Completed, Phase::Stopped}, "已停止", Phase::Stopped}};
        for (const auto &example : examples) {
            auto value = summary(example.phases);
            QCOMPARE(value.leftText, example.text);
            QCOMPARE(value.leftPhase, example.phase);
        }
    }
    void testQuotaShowsRemainingPercentAndSortsActualWindows() {
        QuotaSnapshot quota{instant, {{10080, 39}, {300, 18}}, QuotaOrigin::Account};
        auto value = summary({}, false, quota);
        QCOMPARE(value.quotaLines, QStringList({"5h 82%", "周 61%"}));
        QVERIFY(!value.isQuotaStale);
    }
    void testMissingQuotaDoesNotInventAWindowOrBalance() {
        QCOMPARE(summary({}).quotaLines, QStringList({"额度暂无数据"}));
        QCOMPARE(summary({}, false, QuotaSnapshot{instant, {}}).quotaLines, QStringList({"额度暂无数据"}));
        QCOMPARE(summary({}, false, QuotaSnapshot{instant, {{10080, 40}}}).quotaLines, QStringList({"周 60%"}));
    }
    void testNonstandardWindowsKeepTheirPeriodsAndOutputIsLimitedToTwoLines() {
        QuotaSnapshot quota{instant, {{10080, 10}, {120, 12.5}, {15, 105}}};
        QCOMPARE(summary({}, false, quota).quotaLines, QStringList({"15m 0%", "2h 88%"}));
    }
    void testFiveMinuteAgeBoundaryMarksHistoryWithoutFabricatingNewBalance() {
        const QList<QuotaWindow> windows{{300, 20}};
        const QuotaSnapshot boundary{instant.addSecs(-300), windows}, older{instant.addMSecs(-300010), windows};
        QVERIFY(!summary({}, false, boundary).isQuotaStale);
        auto value = summary({}, false, older);
        QVERIFY(value.isQuotaStale);
        QCOMPARE(value.quotaLines, QStringList({"5h 80%"}));
    }
    void testResetBoundaryHidesOnlyTheExpiredPercentage() {
        QuotaSnapshot quota{instant, {{300, 90, instant}, {10080, 40, instant.addSecs(1)}}};
        auto value = summary({}, false, quota);
        QCOMPARE(value.quotaLines, QStringList({"5h 待更新", "周 60%"}));
        QVERIFY(value.isQuotaStale);
    }
};
QTEST_APPLESS_MAIN(CompactMonitorSummaryTests)
#include "test_compact_monitor_summary.moc"
