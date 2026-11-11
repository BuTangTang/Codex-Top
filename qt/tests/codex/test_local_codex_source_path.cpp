#include "local_source_fixture.h"
#include "local_source_links.h"
#include <QProcess>
#include <ctime>
#ifndef Q_OS_WIN
#include <unistd.h>
#include <sys/stat.h>
#endif
using namespace local_fixture;
namespace {
// 整个路径越界时，不应读取任何数据或透露外部任务状态。
void blocked(const SourceSnapshot &s) {
    QCOMPARE(s.tasks.first().activity.phase, TaskPhase::Unknown);
    QCOMPARE(s.tasks.first().activity.detail, QStringLiteral("记录位于数据目录之外，未读取"));
    QCOMPARE(s.bytesRead, 0);
    QVERIFY(s.warning.has_value());
}
void resolved(const SourceSnapshot &s, const QString &expected) {
    QCOMPARE(s.tasks.first().rolloutPath, expected);
    QCOMPARE(QUrl::fromLocalFile(s.tasks.first().rolloutPath), QUrl::fromLocalFile(expected));
    QCOMPARE(QFileInfo(s.tasks.first().rolloutPath).isDir(), QFileInfo(expected).isDir());
}
void phase(const SourceSnapshot &s, TaskPhase p) {
    QCOMPARE(s.tasks.first().activity.phase, p);
}
} // namespace
class LocalCodexSourcePathTests : public QObject {
    Q_OBJECT
  private slots:
    // 末级链接每轮重新解析，改到目录外时不读正文，改回后恢复真实状态。
    void testLeafSymlinkRetargetsInsideOutsideInside() {
        Fixture f;
        const auto first = f.path("first.jsonl"), second = f.path("second.jsonl"),
                   outside = f.outside + "/outside.jsonl", link = f.path("current.jsonl");
        write(first, local_fixture::event("task_complete"));
        write(second, local_fixture::event("task_started"));
        write(outside, local_fixture::event("task_started"));
        QVERIFY(symlink(link, first));
        f.add("synthetic", link);
        LocalCodexSource src(f.root);
        auto initial = src.snapshot(now);
        phase(initial, TaskPhase::Completed);
        QVERIFY(initial.bytesRead > 0);
        resolved(initial, first);
        QVERIFY(unlinkFixture(link));
        QVERIFY(symlink(link, outside));
        auto escaped = src.snapshot(now);
        blocked(escaped);
        resolved(escaped, outside);
        QVERIFY(unlinkFixture(link));
        QVERIFY(symlink(link, second));
        auto returned = src.snapshot(now);
        phase(returned, TaskPhase::Running);
        QVERIFY(returned.bytesRead > 0);
        QVERIFY(!returned.warning);
        resolved(returned, second);
    }
    // 祖先目录链接改指也必须立即生效，不能复用上一轮的已解析父目录。
    void testAncestorSymlinkRetargetsInsideOutsideInside() {
        Fixture f;
        const QString first = f.path("first"), second = f.path("second"), link = f.path("sessions"),
                      leaf = "/task.jsonl";
        write(first + leaf, local_fixture::event("task_complete"));
        write(second + leaf, local_fixture::event("task_started"));
        write(f.outside + leaf, local_fixture::event("task_started"));
        QVERIFY(symlink(link, first, true));
        f.add("synthetic", link + leaf);
        LocalCodexSource src(f.root);
        phase(src.snapshot(now), TaskPhase::Completed);
        QVERIFY(unlinkFixture(link));
        QVERIFY(symlink(link, f.outside, true));
        auto escaped = src.snapshot(now);
        blocked(escaped);
        resolved(escaped, f.outside + leaf);
        QVERIFY(unlinkFixture(link));
        QVERIFY(symlink(link, second, true));
        auto returned = src.snapshot(now);
        phase(returned, TaskPhase::Running);
        QVERIFY(returned.bytesRead > 0);
        QVERIFY(!returned.warning);
        resolved(returned, second + leaf);
    }
    // 悬空链接、目标恢复及再次消失沿用未知状态和错误恢复，不缓存旧文件结果。
    void testDanglingLinkRecoversAndBecomesMissingAgain() {
        Fixture f;
        auto dest = f.path("later/task.jsonl"), link = f.path("current.jsonl");
        QVERIFY(symlink(link, dest));
        f.add("synthetic", link);
        LocalCodexSource src(f.root);
        auto missing = src.snapshot(now);
        phase(missing, TaskPhase::Unknown);
        QCOMPARE(missing.bytesRead, 0);
        QVERIFY(missing.warning);
        resolved(missing, link);
        write(dest, local_fixture::event("task_started"));
        auto s = src.snapshot(now);
        phase(s, TaskPhase::Running);
        QVERIFY(s.bytesRead > 0);
        QVERIFY(!s.warning);
        resolved(s, dest);
        QVERIFY(QFile::remove(dest));
        auto again = src.snapshot(now);
        phase(again, TaskPhase::Unknown);
        QCOMPARE(again.bytesRead, 0);
        QVERIFY(again.warning);
        resolved(again, link);
    }
    // 相对路径、Unicode、空格及链接后的上级分量均与原 Foundation 解析结果严格一致。
    void testRelativeUnicodeAndLinkedParentComponentsMatchOriginalResolution() {
        Fixture f;
#ifdef Q_OS_WIN
        const QString leaf = QStringLiteral("会话 空格 %20 #？.jsonl");
#else
        const QString leaf = QStringLiteral("会话 空格 %20 #?.jsonl");
#endif
        const QString dir = f.path("中文目录"), nested = dir + "/nested", link = f.path("alias");
        QVERIFY(QDir().mkpath(nested));
        write(dir + '/' + leaf, local_fixture::event("task_complete"));
        QVERIFY(symlink(link, nested, true));
        // 和 Swift standardizedFileURL 一样，先规范化输入的 .. 再按现存目标解析链接。
        const QString expected = f.path(leaf);
        write(expected, local_fixture::event("task_complete"));
        const auto relative = QDir::current().relativeFilePath(f.root) + "/alias/../" + leaf;
        f.add("synthetic", relative);
        LocalCodexSource src(f.root);
        auto s = src.snapshot(now);
        phase(s, TaskPhase::Completed);
        QVERIFY(s.bytesRead > 0);
        QVERIFY(!s.warning);
        resolved(s, expected);
    }
    // 根目录双斜杠保持原路径规范化规则；只登记不存在的合成路径，不在根目录写文件。
    void testRootDoubleSlashKeepsCanonicalPathAcrossWarmSnapshots() {
        Fixture f;
        const auto leaf = "codex-top-missing-" + QUuid::createUuid().toString() + ".jsonl";
#ifdef Q_OS_WIN
        const QString volume = QFileInfo(f.root).absoluteDir().rootPath();
        const auto raw = volume + '/' + leaf, expected = volume + leaf;
#else
        const auto raw = "//" + leaf, expected = '/' + leaf;
#endif
        f.add("synthetic", raw);
        LocalCodexSource src(f.root);
        for (int i = 0; i < 2; ++i) {
            auto s = src.snapshot(now);
            blocked(s);
            resolved(s, expected);
        }
    }
    // 相同前缀的兄弟目录仍被拒绝，不能把简单字符串前缀当成目录包含关系。
    void testSiblingPrefixIsOutsideWithoutReadingItsEvent() {
        Fixture f;
        auto file = f.base + "/root-other/event.jsonl";
        write(file, local_fixture::event("task_started"));
        f.add("synthetic", file);
        LocalCodexSource src(f.root);
        auto s = src.snapshot(now);
        blocked(s);
        resolved(s, file);
    }
    // 错把目录或循环链接登记为记录时仍给出未知，文件恢复后重新读取。
    void testDirectoryAndLinkLoopStayUnknownThenRecover() {
        Fixture f;
        auto entry = f.path("event.jsonl");
        QVERIFY(QDir().mkpath(entry));
        f.add("synthetic", entry);
        LocalCodexSource src(f.root);
        auto s = src.snapshot(now);
        phase(s, TaskPhase::Unknown);
        QCOMPARE(s.bytesRead, 0);
        QVERIFY(s.warning);
        resolved(s, entry);
        QVERIFY(QDir().rmdir(entry));
        QVERIFY(symlink(entry, "event.jsonl"));
        auto loop = src.snapshot(now);
        phase(loop, TaskPhase::Unknown);
        QCOMPARE(loop.bytesRead, 0);
        QVERIFY(loop.warning);
        resolved(loop, entry);
        QVERIFY(unlinkFixture(entry));
        write(entry, local_fixture::event("task_complete"));
        auto back = src.snapshot(now);
        phase(back, TaskPhase::Completed);
        QVERIFY(!back.warning);
    }
    // 快速路径中的百分号、空格、中文和保留字符保持同一实际文件，不重复解码路径。
    void testAbsoluteSpecialCharactersKeepFileIdentityAcrossSnapshots() {
        Fixture f;
        auto p = f.path("中文目录/会话 空格 %20 #?.jsonl");
#ifdef Q_OS_WIN
        // Windows 文件名禁止 ASCII 问号，用全角问号覆盖同一段未编码的 Unicode 路径。
        p.replace('?', QChar(0xff1f));
#endif
        write(p, local_fixture::event("task_complete"));
        f.add("synthetic", p);
        LocalCodexSource src(f.root);
        for (int i = 0; i < 2; ++i) {
            auto s = src.snapshot(now);
            phase(s, TaskPhase::Completed);
            QVERIFY(!s.warning);
            resolved(s, p);
        }
        QVERIFY(QFile::remove(p));
        phase(src.snapshot(now), TaskPhase::Unknown);
        write(p, local_fixture::event("task_started"));
        auto s = src.snapshot(now);
        phase(s, TaskPhase::Running);
        resolved(s, p);
    }
    // 父目录内的直接缺失叶创建、删除、目录重建后，下一快照必须看到当前文件。
    void testMissingDirectLeafRecoversAfterCreateAndDirectoryReplacement() {
        Fixture f;
        auto dir = f.path("history"), p = dir + "/later.jsonl";
        QVERIFY(QDir().mkpath(dir));
        f.add("synthetic", p);
        LocalCodexSource src(f.root);
        for (int i = 0; i < 2; ++i)
            phase(src.snapshot(now), TaskPhase::Unknown);
        write(p, local_fixture::event("task_complete"));
        phase(src.snapshot(now), TaskPhase::Completed);
        QVERIFY(QDir(dir).removeRecursively());
        phase(src.snapshot(now), TaskPhase::Unknown);
        QVERIFY(QDir().mkpath(dir));
        src.snapshot(now);
        write(p, local_fixture::event("task_started"));
        phase(src.snapshot(now), TaskPhase::Running);
    }
    // 缺失结果不能掩盖父目录权限失败，恢复权限并创建文件后立即恢复。
    void testMissingDirectLeafDoesNotCacheParentPermissionFailure() {
#ifndef Q_OS_WIN
        if (!geteuid())
            QSKIP("root 绕过目录权限");
#endif
        Fixture f;
        auto dir = f.path("private"), p = dir + "/later.jsonl";
        QVERIFY(QDir().mkpath(dir));
        f.add("synthetic", p);
        LocalCodexSource src(f.root);
        src.snapshot(now);
#ifdef Q_OS_WIN
        QProcess who;
        who.start("whoami.exe", QStringList{});
        QVERIFY(who.waitForFinished());
        const auto user = QString::fromLocal8Bit(who.readAllStandardOutput()).trimmed();
        auto acl = [&](QStringList args) {
            QProcess proc;
            proc.start("icacls.exe", args);
            return proc.waitForFinished() && proc.exitCode() == 0;
        };
        // 拒绝活动目录的文件遍历和读取，在恢复 ACL 前先取得实际快照，避免测试夹具残留。
        QVERIFY(acl({QDir::toNativeSeparators(dir), "/deny", user + ":(OI)(CI)(RX)"}));
        auto s = src.snapshot(now);
        QVERIFY(acl({QDir::toNativeSeparators(dir), "/remove:d", user}));
#else
        QVERIFY(::chmod(QFile::encodeName(dir).constData(), 0) == 0);
        auto s = src.snapshot(now);
        QVERIFY(::chmod(QFile::encodeName(dir).constData(), 0700) == 0);
#endif
        phase(s, TaskPhase::Unknown);
        QCOMPARE(s.tasks.first().activity.detail, QStringLiteral("无权读取任务记录"));
        write(p, local_fixture::event("task_complete"));
        phase(src.snapshot(now), TaskPhase::Completed);
    }
    // 已缓存的缺失叶不能跟随祖先链接跨目录复用，外部目标保持拒读。
    void testMissingLeafAncestorRetargetsAndReturns() {
        Fixture f;
        const QString first = f.path("first"), second = f.path("second"), link = f.path("alias"), leaf = "/later.jsonl";
        QVERIFY(QDir().mkpath(first));
        write(second + leaf, local_fixture::event("task_started"));
        write(f.outside + leaf, local_fixture::event("task_complete"));
        QVERIFY(symlink(link, first, true));
        f.add("synthetic", link + leaf);
        LocalCodexSource src(f.root);
        src.snapshot(now);
        QVERIFY(unlinkFixture(link));
        QVERIFY(symlink(link, f.outside, true));
        blocked(src.snapshot(now));
        QVERIFY(unlinkFixture(link));
        QVERIFY(symlink(link, second, true));
        auto s = src.snapshot(now);
        phase(s, TaskPhase::Running);
        resolved(s, second + leaf);
    }
    // 即使外部程序恢复目录mtime，创建叶文件引起的ctime仍使缺失证据失效。
    void testMissingLeafCreationWithRestoredParentModificationDate() {
        Fixture f;
        auto dir = f.path("history"), p = dir + "/later.jsonl";
        QVERIFY(QDir().mkpath(dir));
        const auto fs = std::filesystem::path(dir.toStdU16String());
        auto stamp = std::filesystem::last_write_time(fs) - std::chrono::hours(24 * 10);
        std::filesystem::last_write_time(fs, stamp);
        f.add("synthetic", p);
        LocalCodexSource src(f.root);
        src.snapshot(now);
        write(p, local_fixture::event("task_complete"));
        std::filesystem::last_write_time(fs, stamp);
        phase(src.snapshot(now), TaskPhase::Completed);
    }
    // 在同一1500条合成快照上观测暖轮询CPU，不用机器相关耗时作为正确性断言。
    void testLargeMixedHistorySnapshotCost() {
        Fixture f;
        QVERIFY(f.db.transaction());
        for (int i = 0; i < 1500; ++i) {
            auto id = "task-" + QString::number(i), p = f.path("history/" + id + ".jsonl");
            if (i < 500)
                write(p, local_fixture::event("task_complete"));
            else
                write(p + ".zst", {});
            f.add(id, p);
        }
        QVERIFY(f.db.commit());
        LocalCodexSource src(f.root);
        src.snapshot(now);
        auto start = std::clock();
        for (int n = 0; n < 20; ++n) {
            auto s = src.snapshot(now);
            QCOMPARE(s.tasks.size(), 1500);
            QCOMPARE(std::count_if(s.tasks.cbegin(), s.tasks.cend(),
                                   [](const CodexTask &t) { return t.activity.phase == TaskPhase::Completed; }),
                     500);
            QCOMPARE(s.bytesRead, 0);
        }
        qInfo() << "Mixed history snapshot CPU: rows=1500 iterations=20 seconds="
                << double(std::clock() - start) / CLOCKS_PER_SEC;
    }
};
QTEST_GUILESS_MAIN(LocalCodexSourcePathTests)
#include "test_local_codex_source_path.moc"
