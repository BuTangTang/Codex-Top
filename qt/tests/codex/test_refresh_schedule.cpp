#include "codex/refresh_schedule.h"
#include <QTemporaryDir>
#include <QFile>
#include <QtTest>
using namespace codextop;

class RefreshScheduleTests : public QObject {
    Q_OBJECT
  private slots:
    // 延迟完成第一轮，模拟文件变化时扫描仍在进行；忙碌期间不并发，完成后补读。
    void waitingChildWriteSurvivesBusyRefresh() {
        QTemporaryDir dir;
        QFile file(dir.filePath("child.jsonl"));
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.close();
        CodexTask child;
        child.id = "child";
        child.activity.phase = TaskPhase::Waiting;
        child.rolloutPath = file.fileName();
        RefreshSchedule schedule;
        QSignalSpy requests(&schedule, &RefreshSchedule::refreshRequested);
        schedule.updateWatches({child}, {{"child", "parent"}}, {"parent"});
        schedule.start();
        QCOMPARE(requests.size(), 1);
        QVERIFY(file.open(QIODevice::Append));
        QVERIFY(file.write("synthetic\n") > 0);
        file.close();
        QTest::qWait(300);
        QCOMPARE(requests.size(), 1);
        QVERIFY(schedule.finish(requests.at(0).at(0).toULongLong()));
        QTRY_COMPARE_WITH_TIMEOUT(requests.size(), 2, 1400);
        schedule.stop();
        QVERIFY(!schedule.finish(requests.at(1).at(0).toULongLong()));
    }
    // 暂停自动读取后仍可手动刷新，切换目录时明确丢弃旧读取，恢复后重新读取。
    void pauseAndSourceReplacementPreserveManualRefresh() {
        RefreshSchedule schedule;
        QSignalSpy requests(&schedule, &RefreshSchedule::refreshRequested);
        schedule.setPaused(true);
        schedule.start();
        QCOMPARE(requests.size(), 0);
        schedule.refreshManually();
        QCOMPARE(requests.size(), 1);
        schedule.resetSource();
        QVERIFY(!schedule.finish(requests.at(0).at(0).toULongLong()));
        schedule.setPaused(false);
        QTRY_COMPARE_WITH_TIMEOUT(requests.size(), 2, 1000);
        QVERIFY(schedule.finish(requests.at(1).at(0).toULongLong()));
    }
};
QTEST_GUILESS_MAIN(RefreshScheduleTests)
#include "test_refresh_schedule.moc"
