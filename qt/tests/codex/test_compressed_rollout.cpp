#include "codex/compressed_rollout_reader.h"
#include "local_source_fixture.h"
using namespace local_fixture;
using Reader = CompressedRolloutReader;
using C = Reader::Category;
namespace {
// 官方 Zstandard 原始块格式，能合成多帧和截断帧，无需外部压缩程序。
QByteArray frame(const QByteArray &bytes) {
    QByteArray a = QByteArray::fromHex("28b52ffda0");
    auto put = [&](quint32 n, int width) {
        for (int i = 0; i < width; ++i)
            a.append(char(n >> (8 * i)));
    };
    put(bytes.size(), 4);
    qsizetype at = 0;
    do {
        auto n = qMin<qsizetype>(65536, bytes.size() - at);
        put(quint32(n << 3) | (at + n == bytes.size()), 3);
        a.append(bytes.constData() + at, n);
        at += n;
    } while (at < bytes.size());
    return a;
}
QByteArray cevent(const QByteArray &type) {
    return "{\"timestamp\":\"2027-01-15T08:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"" + type +
           "\",\"turn_id\":\"fixture\"}}\n";
}
Reader::Result finish(Reader &r, const QString &p) {
    Reader::Result result;
    for (int i = 0; i < 100; ++i) {
        r.beginCycle({"fixture"});
        result = r.read("fixture", p, now);
        if (result.category != C::Reading)
            break;
        r.waitForBackgroundRead();
    }
    return result;
}
QByteArray longLine(QByteArray kind, QByteArray head, QByteArray filler = "output") {
    return "{\"timestamp\":\"2027-01-15T08:00:00Z\",\"type\":\"" + kind + "\",\"payload\":{" + head + ",\"" + filler +
           "\":\"" + QByteArray(70000, 'x') + "\"}}\n";
}
} // namespace
class CompressedRolloutTests : public QObject {
    Q_OBJECT
  private slots:
    // 使用官方 v1.5.7 生成的真实压缩块，覆盖 Huffman/FSE 解码路径。
    void testRealCompressedBlock() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, QByteArray::fromBase64(
                     "KLUv/WBWAz0DADIGFhtwadvmymjyYe03IiI2kmK4qiuJlzYol6rPVUSA57kuTC/Y4fiDrWRhtBXhVQwr0bId/"
                     "JEK0iQfHdF2daIKPV656aMX7vAOB0cIqKQuCYwzjufNbrqs7wQDAMjLoRis7AuBUGc="));
        Reader r;
        QCOMPARE(finish(r, p).activity.phase, TaskPhase::Completed);
    }
    // 大窗口在分配历史缓冲前被拒绝，不允许突破窗口预算。
    void testOversizedWindowIsLimited() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, QByteArray::fromHex("28b52ffd0078010000"));
        Reader r;
        QCOMPARE(finish(r, p).category, C::Limited);
    }
    // 完整拼接帧使用最终状态，暖刷新不再读取正文。
    void testMultipleFramesAndWarmCache() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, frame(cevent("task_started")) + frame(cevent("task_complete")));
        Reader r;
        QCOMPARE(finish(r, p).activity.phase, TaskPhase::Completed);
        auto warm = finish(r, p);
        QCOMPARE(warm.bytes, 0);
        QCOMPARE(warm.category, C::Ready);
    }
    // 尾部截断或非法尾随字节不能发布前面已经读到的完成状态。
    void testTruncatedAndTrailingGarbage() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        auto valid = frame(cevent("task_complete"));
        for (const auto &invalid : {valid.chopped(3), valid + QByteArray::fromHex("01020304"), QByteArray{}}) {
            write(p, invalid);
            Reader r;
            auto s = finish(r, p);
            QCOMPARE(s.category, C::Unavailable);
            QCOMPARE(s.activity.phase, TaskPhase::Unknown);
        }
    }
    // 累计输出受限结果缓存，替换成小文件后自动重新读取。
    void testLimitCachesAndReplacementRecovers() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, frame(QByteArray(4096, ' ')));
        Reader r(1024);
        QCOMPARE(finish(r, p).category, C::Limited);
        QCOMPARE(finish(r, p).bytes, 0);
        replaceFile(p, frame(cevent("task_complete")));
        QCOMPARE(finish(r, p).activity.phase, TaskPhase::Completed);
    }
    // 超长行及未结束行保持未知，不把缺失生命周期证据当成成功。
    void testOversizedAndUnterminatedLines() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        for (const auto &bytes :
             {QByteArray(70000, ' ') + '\n' + cevent("task_complete"), cevent("task_complete").chopped(1)}) {
            write(p, frame(bytes));
            Reader r;
            QCOMPARE(finish(r, p).category, C::Limited);
        }
    }
    // 解码块边界两侧和恰好64KiB的合法行保持完整；超过后按行首字段摘要，生命周期事件照常生效。
    void testLineLengthAtOutputBlockBoundary() {
        QTemporaryDir dir;
        const auto p = dir.filePath("boundary.zst");
        for (int n : {65535, 65536, 65537}) {
            auto line = cevent("task_complete").chopped(1);
            line.append(QByteArray(n - line.size(), ' '));
            line += '\n';
            write(p, frame('\n' + line));
            Reader r;
            auto s = finish(r, p);
            QCOMPARE(s.category, C::Ready);
            QCOMPARE(s.activity.phase, TaskPhase::Completed);
        }
    }
    // 同一时间只解一个文件，其余排队；取消关注后停掉它的后台解码，轮到下一个。
    void testSingleDecoderAndCancellation() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, frame(QByteArray(6 * 1024 * 1024, ' ')));
        Reader r;
        r.beginCycle({"a", "b"});
        QCOMPARE(r.read("a", p, now).activity.detail, QStringLiteral("正在读取压缩记录"));
        QCOMPARE(r.read("b", p, now).activity.detail, QStringLiteral("等待读取压缩记录"));
        r.beginCycle({"b"});
        QCOMPARE(r.read("b", p, now).activity.detail, QStringLiteral("正在读取压缩记录"));
        r.waitForBackgroundRead();
        r.beginCycle({"b"});
        auto result = r.read("b", p, now);
        QVERIFY(result.category != C::Reading);
        QVERIFY(result.bytes > 0);
    }
    // 后台一次读完，不再按每轮 4 MiB／20 ms 切片：6 MiB 的记录启动后下一次刷新就拿到结果。
    void testLargeFileFinishesInOneBackgroundPass() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, frame(cevent("task_started") + QByteArray(6 * 1024 * 1024, '\n') + cevent("task_complete")));
        Reader r;
        r.beginCycle({"fixture"});
        QCOMPARE(r.read("fixture", p, now).category, C::Reading);
        r.waitForBackgroundRead();
        r.beginCycle({"fixture"});
        QCOMPARE(r.read("fixture", p, now).activity.phase, TaskPhase::Completed);
    }
    // 解码中替换文件会取消旧流，不把旧完成事件带入新文件。
    void testReplacementDuringDecode() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, frame(QByteArray(6 * 1024 * 1024, ' ')));
        Reader r;
        r.beginCycle({"fixture"});
        QCOMPARE(r.read("fixture", p, now).category, C::Reading);
        replaceFile(p, frame(cevent("task_complete")));
        QCOMPARE(finish(r, p).activity.phase, TaskPhase::Completed);
    }
    // 缓存达到数量上限不循环淘汰重读；取消关注后可释放名额。
    void testCacheCapacityDoesNotThrash() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        write(p, frame(cevent("task_complete")));
        Reader r;
        QSet<QString> ids;
        for (int i = 0; i < 257; ++i)
            ids.insert(QString::number(i));
        for (int i = 0; i < 256; ++i) {
            auto id = QString::number(i);
            r.beginCycle(ids);
            QCOMPARE(r.read(id, p, now).category, C::Reading);
            r.waitForBackgroundRead();
            r.beginCycle(ids);
            QCOMPARE(r.read(id, p, now).category, C::Ready);
        }
        r.beginCycle(ids);
        QCOMPARE(r.read("256", p, now).category, C::Limited);
        QCOMPARE(r.read("0", p, now).bytes, 0);
        r.beginCycle({"256"});
        QCOMPARE(r.read("256", p, now).category, C::Reading);
        r.waitForBackgroundRead();
        r.beginCycle({"256"});
        QCOMPARE(r.read("256", p, now).category, C::Ready);
    }
    // 关注根包含压缩子任务；未关注历史缺失不报全库故障，普通文件恢复立即优先。
    void testSourceScopeAndPlainRecovery();
    void testIrrelevantAndSummarizableLongLines() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        auto content = cevent("task_started") + longLine("compacted", "\"message\":\"m\"", "replacement") +
                       longLine("response_item", "\"type\":\"function_call_output\",\"call_id\":\"c1\"") +
                       longLine("event_msg",
                                "\"type\":\"item_completed\",\"turn_id\":\"fixture\",\"item\":{\"type\":"
                                "\"commandExecution\",\"id\":\"i\"",
                                "aggregatedOutput")
                           .chopped(4) +
                       "\"}}}\n" + longLine("response_item", "\"type\":\"message\",\"role\":\"user\"", "content") +
                       cevent("task_complete");
        write(p, frame(content));
        Reader r;
        auto s = finish(r, p);
        QCOMPARE(s.category, C::Ready);
        QCOMPARE(s.activity.phase, TaskPhase::Completed);
    }
    void testLongLinesThatDecideStateWithoutFieldsStayUnknown() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst");
        for (const auto &line :
             {longLine("response_item", "\"type\":\"function_call\",\"name\":\"request_user_input\"", "arguments"),
              longLine("response_item", "\"type\":\"function_call_output\""),
              longLine("event_msg", "\"type\":\"token_count\"", "info")}) {
            write(p, frame(cevent("task_started") + line + cevent("task_complete")));
            Reader r;
            QCOMPARE(finish(r, p).category, C::Limited);
        }
    }
    void testLongLineSummaryKeepsOnlyTopLevelFields() {
        auto s = Reader::summarizeLongLine("{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"type\":"
                                           "\"function_call\",\"name\":\"shell\",\"arguments\":\"{\\\"cmd\\\":");
        QCOMPARE(s.kind, Reader::LongLine::Line);
        auto payload = QJsonDocument::fromJson(s.data).object()["payload"].toObject();
        QCOMPARE(payload["name"].toString(), "shell");
        QVERIFY(!payload.contains("arguments"));
        QCOMPARE(Reader::summarizeLongLine(QByteArray(100, ' ')).kind, Reader::LongLine::Gap);
        const QByteArray context = "{\"timestamp\":\"t\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"x";
        QCOMPARE(Reader::summarizeLongLine(context).kind, Reader::LongLine::Ignore);
    }
    void testFinishedResultsPersistAcrossRestartsAndExpireOnChange() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst"), cache = dir.filePath("state/cache.json");
        write(p, frame(cevent("task_started") + cevent("task_complete")));
        {
            Reader r(qint64(1) << 46, cache);
            QCOMPARE(finish(r, p).activity.phase, TaskPhase::Completed);
        }
        Reader restarted(qint64(1) << 46, cache);
        restarted.beginCycle({"fixture"});
        auto warm = restarted.read("fixture", p, now);
        QCOMPARE(warm.bytes, 0);
        QCOMPARE(warm.activity.phase, TaskPhase::Completed);
        replaceFile(p, frame(cevent("task_started") + cevent("task_failed")));
        Reader third(qint64(1) << 46, cache);
        QCOMPARE(finish(third, p).activity.phase, TaskPhase::Failed);
    }
    // 压缩纯导入记录重启后仍用版本 2 的结果；旧版缓存或出现本机续聊时重新读取。
    void testAutomaticCopyCacheMigrationAndLocalContinuation() {
        QTemporaryDir dir;
        const QString path = dir.filePath("team.zst"), cache = dir.filePath("cache.json");
        const QByteArray history = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"teamchat_copy\":{\"automatic\":true}}}\n"
                                   "{\"ordinal\":1,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n";
        write(path, frame(history));
        auto restored = [&] {
            Reader r(qint64(1) << 46, cache);
            return finish(r, path);
        };
        QCOMPARE(restored().activity, TaskActivity::teamChatImport());
        const auto warm = restored();
        QCOMPARE(warm.activity, TaskActivity::teamChatImport());
        QCOMPARE(warm.bytes, 0);
        auto legacy = QJsonDocument::fromJson(readFile(cache)).object();
        QVERIFY(!legacy.isEmpty());
        legacy["version"] = 1;
        write(cache, QJsonDocument(legacy).toJson());
        const auto migrated = restored();
        QCOMPARE(migrated.activity, TaskActivity::teamChatImport());
        QVERIFY(migrated.bytes > 0);
        replaceFile(path,frame(history + cevent("task_complete")));
        const auto local = restored();
        QCOMPARE(local.activity.phase, TaskPhase::Completed);
        QVERIFY(!local.activity.isTeamChatImport);
    }

    // 纯导入长行缺少来源时保持未知，真正的本机续聊仍可从大工具输出读到完成。
    void testAutomaticCopyKeepsNativeCompletionAfterLongToolOutput() {
        QTemporaryDir dir;
        const auto path = dir.filePath("team.zst");
        const QByteArray header = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"teamchat_copy\":{\"automatic\":true}}}\n";
        const auto output = longLine("response_item", "\"type\":\"function_call_output\",\"call_id\":\"answer\"");
        const auto compacted = longLine("compacted", "\"message\":\"m\"", "replacement");
        write(path,frame(header + compacted + cevent("task_started") + output + cevent("task_complete")));
        Reader reader;
        const auto local = finish(reader,path);
        QCOMPARE(local.category,C::Ready);
        QCOMPARE(local.activity.phase,TaskPhase::Completed);
        replaceFile(path,frame(header + output));
        Reader after;
        const auto unconfirmed = finish(after,path);
        QCOMPARE(unconfirmed.category,C::Limited);
        QVERIFY(!unconfirmed.activity.isTeamChatImport);
    }

    void testWaitingResultsAreNotPersisted() {
        QTemporaryDir dir;
        const auto p = dir.filePath("task.zst"), cache = dir.filePath("cache.json");
        write(p, frame(cevent("task_started") + cevent("request_user_input")));
        {
            Reader r(qint64(1) << 46, cache);
            QCOMPARE(finish(r, p).activity.phase, TaskPhase::Waiting);
        }
        Reader r(qint64(1) << 46, cache);
        r.beginCycle({"fixture"});
        QCOMPARE(r.read("fixture", p, now).category, C::Reading);
    }
};
#include "local_source_links.h"
void CompressedRolloutTests::testSourceScopeAndPlainRecovery() {
    Fixture f;
    QString plain = f.path("child.jsonl"), zst = plain + ".zst";
    write(zst, frame(cevent("task_complete")));
    f.sql("CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)");
    f.add("root", f.path("root.jsonl"), "root", "/fixture");
    f.add("child", plain, "child", "/fixture");
    f.add("other", f.path("missing.jsonl"), "other", "/fixture");
    f.sql("INSERT INTO thread_spawn_edges VALUES('root','child')");
    write(f.path("root.jsonl"), cevent("task_started"));
    LocalCodexSource src(f.root);
    auto none = src.snapshot(now, {}, QSet<QString>{});
    QVERIFY(!none.warning);
    QCOMPARE(task(none, "child").activity.detail, QStringLiteral("历史记录已压缩，尚未读取"));
    auto selected = src.snapshot(now, {}, QSet<QString>{"root"});
    for (int i = 0; i < 20 && task(selected, "child").activity.phase == TaskPhase::Unknown; ++i) {
        QTest::qWait(20);
        selected = src.snapshot(now, {}, QSet<QString>{"root"});
    }
    QVERIFY(!selected.warning);
    QCOMPARE(task(selected, "child").activity.phase, TaskPhase::Completed);
    write(plain, cevent("task_started"));
    auto restored = src.snapshot(now, {}, QSet<QString>{"root"});
    QCOMPARE(task(restored, "child").activity.phase, TaskPhase::Running);
    QVERIFY(QFile::remove(plain));
    QVERIFY(QFile::remove(zst));
    const auto outside = f.outside + "/outside.zst";
    write(outside, frame(cevent("task_complete")));
    QVERIFY2(local_fixture::symlink(zst, outside), "需要测试机允许在临时目录中创建文件系统符号链接");
    auto blocked = src.snapshot(now, {}, QSet<QString>{"root"});
    QCOMPARE(task(blocked, "child").activity.detail, QStringLiteral("记录位于数据目录之外，未读取"));
    QVERIFY(blocked.warning && blocked.warning->contains(QStringLiteral("1 条记录不可用")));
}
QTEST_GUILESS_MAIN(CompressedRolloutTests)
#include "test_compressed_rollout.moc"
