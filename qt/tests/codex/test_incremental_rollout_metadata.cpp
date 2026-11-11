#include "rollout_test_support.h"

#include <filesystem>
#include <system_error>
#ifdef Q_OS_WIN
#include <qt_windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#endif
using namespace rolloutFixture;

class IncrementalRolloutMetadataTests : public QObject {
    Q_OBJECT
    /// 保持每条事件正好 256 字节，等长重写不能靠长度变化识别。
    static QByteArray paddedEvent(const QString &type, const QString &turn = "fixture") {
        return recordEvent(type, 0, {{"turn_id",turn}}).leftJustified(255, ' ') + '\n';
    }
    /// 以原生 API 设定精确修改时间，再回读核对临时卷实际支持的精度。
    static bool setNanos(const QString &path, long nanos) {
#ifdef Q_OS_WIN
        HANDLE h = CreateFileW(reinterpret_cast<LPCWSTR>(path.utf16()), FILE_WRITE_ATTRIBUTES,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) return false;
        const quint64 ticks = (11644473600ULL + 1800000000) * 10000000 + nanos / 100;
        const FILETIME time{DWORD(ticks), DWORD(ticks >> 32)};
        const bool changed = SetFileTime(h, nullptr, nullptr, &time);
        CloseHandle(h);
#else
        const timespec times[2]{{1800000000, nanos},{1800000000,nanos}};
        const bool changed = ::utimensat(AT_FDCWD, QFile::encodeName(path).constData(), times, 0) == 0;
#endif
        return changed && RolloutFileMetadata::read(path).nanoseconds == nanos;
    }
    // APFS 可区分 1 ns；NTFS 的最小 tick 是 100 ns。
#ifdef Q_OS_WIN
    static constexpr int tick = 100;
#else
    static constexpr int tick = 1;
#endif
    /// 使用真正的符号链接（Windows 的 QFile::link 创建 .lnk，语义不同）。
    static std::error_code linkTo(const QString &target, const QString &link) {
        std::error_code error;
        std::filesystem::create_symlink(QFile(target).filesystemFileName(), QFile(link).filesystemFileName(), error);
        return error;
    }
private slots:
    /// 未更改的文件不重读；追加时只读新字节。
    void testUnchangedFileAndAppendPreserveIncrementalCursor() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        const auto first = paddedEvent("task_started"), completion = paddedEvent("task_complete");
        overwrite(path, first);
        IncrementalRollout reader;
        QCOMPARE(reader.refresh(path), first.size());
        QCOMPARE(reader.refresh(path), 0);
        append(path, completion);
        QCOMPARE(reader.refresh(path), completion.size());
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Completed);
        QCOMPARE(reader.offset, first.size() + completion.size());
        QVERIFY(reader.isCaughtUp);
        QCOMPARE(reader.refresh(path), 0);
    }
    /// 同一秒、同一文件、同一长度，仅最小时间刻度不同的改写也要重读。
    void testSameSizeRewritePreservesNanosecondPrecision() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path, paddedEvent("task_started", "old"));
        QVERIFY(setNanos(path, 125000000));
        const auto before = RolloutFileMetadata::read(path);
        IncrementalRollout reader;
        reader.refresh(path);
        overwrite(path, paddedEvent("task_complete", "new"));
        if (!setNanos(path, 125000000 + tick)) QSKIP("合成目录的文件系统未保留最小修改时间刻度");
        const auto after = RolloutFileMetadata::read(path);
        QCOMPARE(before.inode, after.inode);
        QCOMPARE(before.size, after.size);
        QCOMPARE(before.seconds, after.seconds);
        QCOMPARE(reader.refresh(path), after.size);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Completed);
        QVERIFY(!reader.reducer.activity.startedAt && reader.reducer.activity.turnID != QString("old"));
        QCOMPARE(reader.refresh(path), 0);
    }
    /// 文件轮转即使长度和精确时间完全相同也需要丢弃旧状态。
    void testReplacementWithSameSizeAndTimestampDiscardsOldState() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path, paddedEvent("task_started", "old"));
        QVERIFY(setNanos(path, 250000000));
        const auto before = RolloutFileMetadata::read(path);
        IncrementalRollout reader;
        reader.refresh(path);
        QVERIFY(QFile::rename(path, dir.filePath("rotated.jsonl")));
        overwrite(path, paddedEvent("task_complete", "new"));
        QVERIFY(setNanos(path, 250000000));
        const auto after = RolloutFileMetadata::read(path);
        QVERIFY(before.inode != after.inode);
        QCOMPARE(before.size, after.size);
        QCOMPARE(before.nanoseconds, after.nanoseconds);
        QCOMPARE(reader.refresh(path), after.size);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Completed);
        QVERIFY(!reader.reducer.activity.startedAt);
    }
    /// 截断时一并丢弃旧半行，使之后追加的用户输入可以正常解析。
    void testTruncationClearsPendingPartialLine() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path, paddedEvent("task_started") + paddedEvent("task_complete").left(80));
        const auto before = RolloutFileMetadata::read(path);
        IncrementalRollout reader;
        reader.refresh(path);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Running);
        overwrite(path, paddedEvent("task_failed"));
        QCOMPARE(RolloutFileMetadata::read(path).inode, before.inode);
        QCOMPARE(reader.refresh(path), 256);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Failed);
        append(path, paddedEvent("user_message"));
        QCOMPARE(reader.refresh(path), 256);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Running);
    }
    /// 文件消失应报告可辨认的“文件不存在”，并保留游标供下一次刷新恢复。
    void testMissingFilePreservesFoundationErrorAndReaderCanRecover() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path, paddedEvent("task_started"));
        IncrementalRollout reader;
        reader.refresh(path);
        const auto previous = reader.reducer.activity;
        const auto offset = reader.offset;
        QVERIFY(QFile::rename(path, dir.filePath("old.jsonl")));
        try { reader.refresh(path); QFAIL("缺失文件没有返回错误"); }
        catch (const std::system_error &error) { QVERIFY(error.code() == std::errc::no_such_file_or_directory); }
        QCOMPARE(reader.reducer.activity, previous);
        QCOMPARE(reader.offset, offset);
        overwrite(path, paddedEvent("task_complete"));
        QCOMPARE(reader.refresh(path), 256);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Completed);
    }
    /// 末级符号链接按链接自身长度和身份采样，目标追加不会触发重读。
    void testSymbolicLinkMetadataDoesNotFollowTarget() {
        QTemporaryDir dir;
        const auto target = dir.filePath("target.jsonl"), link = dir.filePath("link.jsonl");
        overwrite(target, paddedEvent("task_started"));
        const auto error = linkTo("target.jsonl", link);
#ifdef Q_OS_WIN
        if (error.value() == ERROR_PRIVILEGE_NOT_HELD) QSKIP("当前 Windows 账号无创建符号链接权限");
#endif
        QVERIFY(!error);
        const auto meta = RolloutFileMetadata::read(link);
        QCOMPARE(meta.size, QByteArray("target.jsonl").size());
        QVERIFY(meta.inode != RolloutFileMetadata::read(target).inode);
        IncrementalRollout reader;
        QCOMPARE(reader.refresh(link), meta.size);
        QCOMPARE(reader.offset, meta.size);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Unknown);
        append(target, paddedEvent("task_complete"));
        QCOMPARE(reader.refresh(link), 0);
    }
    /// 断开的符号链接可查询身份，但打开目标仍返回错误。
    void testDanglingSymbolicLinkStillFailsWhenOpeningTarget() {
        QTemporaryDir dir;
        const auto link = dir.filePath("link.jsonl");
        const auto error = linkTo("missing.jsonl", link);
#ifdef Q_OS_WIN
        if (error.value() == ERROR_PRIVILEGE_NOT_HELD) QSKIP("当前 Windows 账号无创建符号链接权限");
#endif
        QVERIFY(!error);
        QVERIFY(!RolloutFileMetadata::read(link).regular);
        IncrementalRollout reader;
        QVERIFY_THROWS_EXCEPTION(std::system_error, reader.refresh(link));
        QCOMPARE(reader.offset, 0);
        QVERIFY(!reader.isCaughtUp);
    }
    /// 时间回查拒绝采样后发生的等长重写；主读取刷新后才接受新代次。
    void testRecoveryRejectsSameSizeRewriteSinceRefresh() {
        QTemporaryDir dir;
        const auto path = dir.filePath("rollout.jsonl");
        overwrite(path, paddedEvent("task_started") + QByteArray(8192,'x') + '\n' + paddedEvent("agent_message"));
        QVERIFY(setNanos(path, 500000000));
        IncrementalRollout reader(1024);
        QCOMPARE(reader.refresh(path), 1024);
        QCOMPARE(reader.reducer.activity.phase, TaskPhase::Running);
        QVERIFY(!reader.reducer.activity.startedAt);
        const auto previous = reader.reducer.activity;
        const auto offset = reader.offset;
        if (!setNanos(path, 500000000 + tick)) QSKIP("合成目录的文件系统未保留最小修改时间刻度");
        QCOMPARE(reader.recoverTiming(path), 0);
        QCOMPARE(reader.reducer.activity, previous);
        QCOMPARE(reader.offset, offset);
        reader.refresh(path);
        QVERIFY(reader.recoverTiming(path) > 0);
        QVERIFY(reader.reducer.activity.startedAt);
        QCOMPARE(reader.offset, offset);
    }
};
QTEST_GUILESS_MAIN(IncrementalRolloutMetadataTests)
#include "test_incremental_rollout_metadata.moc"
