#include "policy/monitor_status_summary.h"
#include <QTest>
using namespace codextop;
using Phase = TaskPhase;
class MonitorStatusSummaryTests : public QObject {
    Q_OBJECT
  private slots:
    void testAttentionKeepsTheConcurrentRunningCount() {
        const MonitorStatusSummary status({Phase::Running, Phase::Running, Phase::Waiting, Phase::Completed});
        QCOMPARE(status.phase, Phase::Waiting);
        QCOMPARE(status.running, 2);
        QCOMPARE(status.attention(), 1);
        const MonitorStatusSummary failed({Phase::Running, Phase::Waiting, Phase::Failed});
        QCOMPARE(failed.phase, Phase::Failed);
        QCOMPARE(failed.running, 1);
        QCOMPARE(failed.attention(), 2);
    }
    void testGreenRequiresAllMonitoredTasksToComplete() {
        QCOMPARE(MonitorStatusSummary({Phase::Completed, Phase::Unknown}).phase, Phase::Unknown);
        QCOMPARE(MonitorStatusSummary({Phase::Completed, Phase::Idle}).phase, Phase::Idle);
        QCOMPARE(MonitorStatusSummary({Phase::Completed, Phase::Stopped}).phase, Phase::Stopped);
        QCOMPARE(MonitorStatusSummary({}).phase, Phase::Idle);
        QCOMPARE(MonitorStatusSummary({Phase::Completed, Phase::Completed}).phase, Phase::Completed);
    }
};
QTEST_APPLESS_MAIN(MonitorStatusSummaryTests)
#include "test_monitor_status_summary.moc"
