import Foundation
import XCTest
import CSQLite
@testable import CodexTopCore

final class CompressedRolloutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 独立临时目录只包含合成事件，测试结束删除。
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// 构造官方帧格式的 raw block，无需机器安装压缩命令。
    private func frame(_ content: Data) -> Data {
        var result = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        let count = UInt32(content.count)
        for shift in [0, 8, 16, 24] { result.append(UInt8(truncatingIfNeeded: count >> shift)) }
        var offset = 0
        repeat {
            let length = min(65_536, content.count - offset)
            let header = UInt32(length << 3) | (offset + length == content.count ? 1 : 0)
            for shift in [0, 8, 16] { result.append(UInt8(truncatingIfNeeded: header >> shift)) }
            result.append(content[offset..<(offset + length)]); offset += length
        } while offset < content.count
        return result
    }
    /// 合成生命周期记录用固定时钟，避免过期判断使测试偶发失败。
    private func event(_ kind: String) -> Data {
        Data("{\"timestamp\":\"2027-01-15T08:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"fixture\"}}\n".utf8)
    }
    /// 有限次驱动原刷新节拍；每轮等后台解码结束再取结果，不使用真实定时器。
    private func finish(_ reader: CompressedRolloutReader, url: URL) -> CompressedRolloutReader.Result {
        var result = CompressedRolloutReader.Result(activity: TaskActivity(), category: .reading)
        for _ in 0..<100 {
            reader.beginCycle(ids: ["fixture"])
            result = reader.read(id: "fixture", url: url, now: now)
            if result.category != .reading { break }
            reader.waitForBackgroundRead()
        }
        return result
    }

    /// 使用官方 v1.5.7 生成的真实压缩块，覆盖 Huffman/FSE 解码路径。
    func testRealCompressedBlock() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try XCTUnwrap(Data(base64Encoded: "KLUv/WBWAz0DADIGFhtwadvmymjyYe03IiI2kmK4qiuJlzYol6rPVUSA57kuTC/Y4fiDrWRhtBXhVQwr0bId/JEK0iQfHdF2daIKPV656aMX7vAOB0cIqKQuCYwzjufNbrqs7wQDAMjLoRis7AuBUGc= ".trimmingCharacters(in: .whitespaces))).write(to: url)
        XCTAssertEqual(finish(CompressedRolloutReader(), url: url).activity.phase, .completed)
    }

    /// 大窗口在分配历史缓冲前被拒绝，不允许突破窗口预算。
    func testOversizedWindowIsLimited() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try Data([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x78, 1, 0, 0]).write(to: url)
        XCTAssertEqual(finish(CompressedRolloutReader(), url: url).category, .limited)
    }

    /// 完整拼接帧使用最终状态，暖刷新不再读取正文。
    func testMultipleFramesAndWarmCache() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try (frame(event("task_started")) + frame(event("task_complete"))).write(to: url)
        let reader = CompressedRolloutReader()
        XCTAssertEqual(finish(reader, url: url).activity.phase, .completed)
        let warm = finish(reader, url: url)
        XCTAssertEqual(warm.bytes, 0)
        XCTAssertEqual(warm.category, .ready)
    }

    /// 尾部截断或非法尾随字节不能发布前面已经读到的完成状态。
    func testTruncatedAndTrailingGarbage() throws {
        let url = try directory().appendingPathComponent("task.zst")
        let valid = frame(event("task_complete"))
        for invalid in [Data(valid.dropLast(3)), valid + Data([1, 2, 3, 4]), Data()] {
            try invalid.write(to: url)
            let result = finish(CompressedRolloutReader(), url: url)
            XCTAssertEqual(result.category, .unavailable)
            XCTAssertEqual(result.activity.phase, .unknown)
        }
    }

    /// 累计输出受限结果缓存，替换成小文件后自动重新读取。
    func testLimitCachesAndReplacementRecovers() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try frame(Data(repeating: 32, count: 4_096)).write(to: url)
        let reader = CompressedRolloutReader(maximumOutput: 1_024)
        XCTAssertEqual(finish(reader, url: url).category, .limited)
        XCTAssertEqual(finish(reader, url: url).bytes, 0)
        try frame(event("task_complete")).write(to: url, options: .atomic)
        XCTAssertEqual(finish(reader, url: url).activity.phase, .completed)
    }

    /// 超长行及未结束行保持未知，不把缺失生命周期证据当成成功。
    func testOversizedAndUnterminatedLines() throws {
        let url = try directory().appendingPathComponent("task.zst")
        for content in [Data(repeating: 32, count: 70_000) + Data([10]) + event("task_complete"), Data(event("task_complete").dropLast())] {
            try frame(content).write(to: url)
            XCTAssertEqual(finish(CompressedRolloutReader(), url: url).category, .limited)
        }
    }

    /// 解码块边界两侧和恰好64KiB的合法行保持完整；超过后按行首字段摘要，生命周期事件照常生效。
    func testLineLengthAtOutputBlockBoundary() throws {
        let url = try directory().appendingPathComponent("boundary.zst")
        for length in [65_535, 65_536, 65_537] {
            var line = Data(event("task_complete").dropLast())
            line.append(Data(repeating: 32, count: length - line.count))
            line.append(10)
            try frame(Data([10]) + line).write(to: url)
            let result = finish(CompressedRolloutReader(), url: url)
            XCTAssertEqual(result.category, .ready)
            XCTAssertEqual(result.activity.phase, .completed)
        }
    }

    /// 同一时间只解一个文件，其余排队；取消关注后停掉它的后台解码，轮到下一个。
    func testSingleDecoderAndCancellation() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try frame(Data(repeating: 32, count: 6 * 1_024 * 1_024)).write(to: url)
        let reader = CompressedRolloutReader()
        reader.beginCycle(ids: ["a", "b"])
        XCTAssertEqual(reader.read(id: "a", url: url, now: now).activity.detail, "正在读取压缩记录")
        XCTAssertEqual(reader.read(id: "b", url: url, now: now).activity.detail, "等待读取压缩记录")
        reader.beginCycle(ids: ["b"])
        XCTAssertEqual(reader.read(id: "b", url: url, now: now).activity.detail, "正在读取压缩记录")
        reader.waitForBackgroundRead()
        reader.beginCycle(ids: ["b"])
        let done = reader.read(id: "b", url: url, now: now)
        XCTAssertNotEqual(done.category, .reading)
        XCTAssertGreaterThan(done.bytes, 0)
    }

    /// 后台一次读完，不再按每轮 4 MiB／20 ms 切片：6 MiB 的记录启动后下一次刷新就拿到结果。
    func testLargeFileFinishesInOneBackgroundPass() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try frame(event("task_started") + Data(repeating: 10, count: 6 * 1_024 * 1_024) + event("task_complete")).write(to: url)
        let reader = CompressedRolloutReader()
        reader.beginCycle(ids: ["fixture"])
        XCTAssertEqual(reader.read(id: "fixture", url: url, now: now).category, .reading)
        reader.waitForBackgroundRead()
        reader.beginCycle(ids: ["fixture"])
        XCTAssertEqual(reader.read(id: "fixture", url: url, now: now).activity.phase, .completed)
    }

    /// 解码中替换文件会取消旧流，不把旧完成事件带入新文件。
    func testReplacementDuringDecode() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try frame(Data(repeating: 32, count: 6 * 1_024 * 1_024)).write(to: url)
        let reader = CompressedRolloutReader()
        reader.beginCycle(ids: ["fixture"])
        XCTAssertEqual(reader.read(id: "fixture", url: url, now: now).category, .reading)
        try frame(event("task_complete")).write(to: url, options: .atomic)
        XCTAssertEqual(finish(reader, url: url).activity.phase, .completed)
    }

    /// 缓存达到数量上限不循环淘汰重读；取消关注后可释放名额。
    func testCacheCapacityDoesNotThrash() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try frame(event("task_complete")).write(to: url)
        let reader = CompressedRolloutReader()
        let ids = Set((0...256).map(String.init))
        for id in 0..<256 {
            reader.beginCycle(ids: ids)
            XCTAssertEqual(reader.read(id: String(id), url: url, now: now).category, .reading)
            reader.waitForBackgroundRead()
            reader.beginCycle(ids: ids)
            XCTAssertEqual(reader.read(id: String(id), url: url, now: now).category, .ready)
        }
        reader.beginCycle(ids: ids)
        XCTAssertEqual(reader.read(id: "256", url: url, now: now).category, .limited)
        XCTAssertEqual(reader.read(id: "0", url: url, now: now).bytes, 0)
        reader.beginCycle(ids: ["256"])
        XCTAssertEqual(reader.read(id: "256", url: url, now: now).category, .reading)
        reader.waitForBackgroundRead()
        reader.beginCycle(ids: ["256"])
        XCTAssertEqual(reader.read(id: "256", url: url, now: now).category, .ready)
    }

    /// 关注根包含压缩子任务；未关注历史缺失不报全库故障，普通文件恢复立即优先。
    func testSourceScopeAndPlainRecovery() async throws {
        let root = try directory()
        let plain = root.appendingPathComponent("child.jsonl")
        try frame(event("task_complete")).write(to: plain.appendingPathExtension("zst"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER);
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT);
        INSERT INTO threads VALUES('root','root','/fixture','\(root.appendingPathComponent("root.jsonl").path)',1,2,0);
        INSERT INTO threads VALUES('child','child','/fixture','\(plain.path)',1,2,0);
        INSERT INTO threads VALUES('other','other','/fixture','\(root.appendingPathComponent("missing.jsonl").path)',1,2,0);
        INSERT INTO thread_spawn_edges VALUES('root','child');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        try event("task_started").write(to: root.appendingPathComponent("root.jsonl"))
        let source = LocalCodexSource(root: root)
        let none = try await source.snapshot(now: now, monitoredRootIDs: [])
        XCTAssertNil(none.warning)
        XCTAssertEqual(none.tasks.first { $0.id == "child" }?.activity.detail, "历史记录已压缩，尚未读取")
        var selected = try await source.snapshot(now: now, monitoredRootIDs: ["root"])
        for _ in 0..<20 where selected.tasks.first(where: { $0.id == "child" })?.activity.phase == .unknown {
            try await Task.sleep(for: .milliseconds(20))  // 解码在后台队列，给它一点时间
            selected = try await source.snapshot(now: now, monitoredRootIDs: ["root"])
        }
        XCTAssertNil(selected.warning)
        XCTAssertEqual(selected.tasks.first { $0.id == "child" }?.activity.phase, .completed)
        try event("task_started").write(to: plain)
        let restored = try await source.snapshot(now: now, monitoredRootIDs: ["root"])
        XCTAssertEqual(restored.tasks.first { $0.id == "child" }?.activity.phase, .running)
        try FileManager.default.removeItem(at: plain)
        let compressedURL = plain.appendingPathExtension("zst")
        try FileManager.default.removeItem(at: compressedURL)
        let outside = try directory().appendingPathComponent("outside.zst")
        try frame(event("task_complete")).write(to: outside)
        try FileManager.default.createSymbolicLink(at: compressedURL, withDestinationURL: outside)
        let blocked = try await source.snapshot(now: now, monitoredRootIDs: ["root"])
        XCTAssertEqual(blocked.tasks.first { $0.id == "child" }?.activity.detail, "记录位于数据目录之外，未读取")
        XCTAssertTrue(blocked.warning?.contains("1 条记录不可用") == true)
    }

    // MARK: 超长行与落盘缓存（2026-11-08 用户同意的规则）

    /// 构造一条超过 64 KiB 的 Codex 记录行，大字段放在最后。
    private func longLine(_ kind: String, _ payloadHead: String, filler: String = "output") -> Data {
        var text = "{\"timestamp\":\"2027-01-15T08:00:00Z\",\"type\":\"\(kind)\",\"payload\":{\(payloadHead),\"\(filler)\":\""
        text += String(repeating: "x", count: 70_000) + "\"}}\n"
        return Data(text.utf8)
    }

    func testIrrelevantAndSummarizableLongLines() throws {
        let url = try directory().appendingPathComponent("task.zst")
        // 压缩摘要、普通工具输出、命令输出与长用户消息都不再让整个任务变成未知。
        let content = event("task_started")
            + longLine("compacted", "\"message\":\"m\"", filler: "replacement")
            + longLine("response_item", "\"type\":\"function_call_output\",\"call_id\":\"c1\"")
            + longLine("event_msg", "\"type\":\"item_completed\",\"turn_id\":\"fixture\",\"item\":{\"type\":\"commandExecution\",\"id\":\"i\"", filler: "aggregatedOutput")
                .dropLast(4) + Data("\"}}}\n".utf8)
            + longLine("response_item", "\"type\":\"message\",\"role\":\"user\"", filler: "content")
            + event("task_complete")
        try frame(content).write(to: url)
        let result = finish(CompressedRolloutReader(), url: url)
        XCTAssertEqual(result.category, .ready)
        XCTAssertEqual(result.activity.phase, .completed)
    }

    func testLongLinesThatDecideStateWithoutFieldsStayUnknown() throws {
        let url = try directory().appendingPathComponent("task.zst")
        let cases: [Data] = [
            // 提问调用的参数在长字段里，读不全就不猜。
            longLine("response_item", "\"type\":\"function_call\",\"name\":\"request_user_input\"", filler: "arguments"),
            // 工具输出没有调用编号，无法判断是否解除等待。
            longLine("response_item", "\"type\":\"function_call_output\"", filler: "output"),
            // 额度记录需要嵌套字段。
            longLine("event_msg", "\"type\":\"token_count\"", filler: "info"),
        ]
        for line in cases {
            try frame(event("task_started") + line + event("task_complete")).write(to: url)
            XCTAssertEqual(finish(CompressedRolloutReader(), url: url).category, .limited)
        }
    }

    func testLongLineSummaryKeepsOnlyTopLevelFields() {
        let prefix = Data("{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"shell\",\"arguments\":\"{\\\"cmd\\\":".utf8)
        guard case .line(let data) = CompressedRolloutReader.summarizeLongLine(prefix),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = value["payload"] as? [String: Any] else { return XCTFail("应生成摘要行") }
        XCTAssertEqual(payload["name"] as? String, "shell")
        XCTAssertNil(payload["arguments"], "参数正文不进入摘要")
        XCTAssertEqual(CompressedRolloutReader.summarizeLongLine(Data(String(repeating: " ", count: 100).utf8)), .gap)
        XCTAssertEqual(CompressedRolloutReader.summarizeLongLine(Data("{\"timestamp\":\"t\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"x".utf8)), .ignore)
    }

    func testFinishedResultsPersistAcrossRestartsAndExpireOnChange() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("task.zst"), cache = folder.appendingPathComponent("state/cache.json")
        try frame(event("task_started") + event("task_complete")).write(to: url)
        XCTAssertEqual(finish(CompressedRolloutReader(cacheURL: cache), url: url).activity.phase, .completed)

        // 新实例（相当于重启）直接用缓存，不再读文件。
        let restarted = CompressedRolloutReader(cacheURL: cache)
        restarted.beginCycle(ids: ["fixture"])
        let warm = restarted.read(id: "fixture", url: url, now: now)
        XCTAssertEqual(warm.bytes, 0)
        XCTAssertEqual(warm.activity.phase, .completed)

        // 文件变了，缓存作废、重新读取。
        try frame(event("task_started") + event("task_failed")).write(to: url, options: .atomic)
        XCTAssertEqual(finish(CompressedRolloutReader(cacheURL: cache), url: url).activity.phase, .failed)
    }

    func testWaitingResultsAreNotPersisted() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("task.zst"), cache = folder.appendingPathComponent("cache.json")
        try frame(event("task_started") + event("request_user_input")).write(to: url)
        XCTAssertEqual(finish(CompressedRolloutReader(cacheURL: cache), url: url).activity.phase, .waiting)
        let restarted = CompressedRolloutReader(cacheURL: cache)
        restarted.beginCycle(ids: ["fixture"])
        XCTAssertEqual(restarted.read(id: "fixture", url: url, now: now).category, .reading, "等待中的结果每次重读")
    }
}
