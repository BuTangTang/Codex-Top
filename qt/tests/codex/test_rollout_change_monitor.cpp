#include "codex/rollout_change_monitor.h"
#include <QFile>
#include <QTemporaryDir>
#include <QThread>
#include <QtTest>

using namespace codextop;
class RolloutChangeMonitorTests : public QObject {
    Q_OBJECT
    // 写完即关闭，让操作系统的文件事件和 Swift 用例一样在一次完整写入后触发。
    static bool write(const QString &path, QByteArray bytes, bool append = false) {
        QFile file(path);
        return file.open(QIODevice::WriteOnly | (append ? QIODevice::Append : QIODevice::Truncate)) &&
               file.write(bytes) == bytes.size();
    }
  private slots:
    void testAppendNotifiesAfterRepeatedIdenticalUpdates() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        QVERIFY(write(path, "synthetic\n"));
        int count = 0;
        bool onMainThread = true;
        RolloutChangeMonitor monitor([&] {
            ++count;
            onMainThread &= QThread::currentThread() == qApp->thread();
        });
        const QSet<QUrl> files{QUrl::fromLocalFile(path)};
        monitor.update(files);
        monitor.update(files);
        QVERIFY(write(path, "changed\n", true));
        QTRY_VERIFY_WITH_TIMEOUT(count > 0, 2000);
        QVERIFY(onMainThread);
    }
    void testRemovalAndStopSuppressQueuedEventsAndAllowRestart() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        QVERIFY(write(path, "synthetic\n"));
        int count = 0;
        RolloutChangeMonitor monitor([&] { ++count; });
        const QSet<QUrl> files{QUrl::fromLocalFile(path)};
        monitor.update(files);
        QVERIFY(write(path, "changed\n", true));
        monitor.update({});
        QVERIFY(write(path, "changed\n", true));
        QTest::qWait(200);
        QCOMPARE(count, 0);
        monitor.update(files);
        QVERIFY(write(path, "changed\n", true));
        monitor.stop();
        QVERIFY(write(path, "changed\n", true));
        QTest::qWait(200);
        QCOMPARE(count, 0);
        monitor.update(files);
        QVERIFY(write(path, "changed\n", true));
        QTRY_VERIFY_WITH_TIMEOUT(count > 0, 2000);
    }
    void testRenamedInodeIsDroppedAndReplacementCanBeWatched() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl"), moved = dir.filePath("previous.jsonl");
        QVERIFY(write(path, "synthetic\n"));
        int count = 0;
        RolloutChangeMonitor monitor([&] { ++count; });
        const QSet<QUrl> files{QUrl::fromLocalFile(path)};
        monitor.update(files);
        QVERIFY(QFile::rename(path, moved));
        QVERIFY(write(path, "replacement\n"));
        QTRY_VERIFY_WITH_TIMEOUT(count > 0, 2000);
        monitor.update(files);
        const int afterRename = count;
        QVERIFY(write(moved, "changed\n", true));
        QTest::qWait(200);
        QCOMPARE(count, afterRename);
        QVERIFY(write(path, "changed\n", true));
        QTRY_VERIFY_WITH_TIMEOUT(count > afterRename, 2000);
    }
    void testReleasingMonitorDoesNotKeepWatchOrCallbackAlive() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        QVERIFY(write(path, "synthetic\n"));
        int count = 0;
        auto monitor = std::make_unique<RolloutChangeMonitor>([&] { ++count; });
        const QPointer<RolloutChangeMonitor> released(monitor.get());
        monitor->update({QUrl::fromLocalFile(path)});
        QVERIFY(write(path, "changed\n", true));
        monitor.reset();
        QVERIFY(released.isNull());
        QVERIFY(write(path, "changed\n", true));
        QTest::qWait(200);
        QCOMPARE(count, 0);
    }
    void testQueuedOldInvalidationCannotRemoveANewWatchAtTheSamePath() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl"), moved = dir.filePath("previous.jsonl");
        QVERIFY(write(path, "synthetic\n"));
        int count = 0;
        RolloutChangeMonitor monitor([&] { ++count; });
        const QSet<QUrl> files{QUrl::fromLocalFile(path)};
        monitor.update(files);
        QVERIFY(QFile::rename(path, moved));
        QVERIFY(write(path, "replacement\n"));
        monitor.stop();
        monitor.update(files);
        QVERIFY(write(moved, "changed\n", true));
        QTest::qWait(200);
        QCOMPARE(count, 0);
        QVERIFY(write(path, "changed\n", true));
        QTRY_VERIFY_WITH_TIMEOUT(count > 0, 2000);
    }
};
QTEST_GUILESS_MAIN(RolloutChangeMonitorTests)
#include "test_rollout_change_monitor.moc"
