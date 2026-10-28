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
    /// 有限次驱动原刷新节拍，不使用真实后台定时器。
    private func finish(_ reader: CompressedRolloutReader, url: URL) -> CompressedRolloutReader.Result {
        var result = CompressedRolloutReader.Result(activity: TaskActivity(), category: .reading)
        for _ in 0..<100 {
            reader.beginCycle(ids: ["fixture"])
            result = reader.read(id: "fixture", url: url, now: now)
            if result.category != .reading { break }
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

    /// 解码块边界两侧和恰好64KiB的合法行保持完整，超过一字节仍受限。
    func testLineLengthAtOutputBlockBoundary() throws {
        let url = try directory().appendingPathComponent("boundary.zst")
        for length in [65_535, 65_536, 65_537] {
            var line = Data(event("task_complete").dropLast())
            line.append(Data(repeating: 32, count: length - line.count))
            line.append(10)
            try frame(Data([10]) + line).write(to: url)
            let result = finish(CompressedRolloutReader(), url: url)
            XCTAssertEqual(result.category, length <= 65_536 ? .ready : .limited)
            XCTAssertEqual(result.activity.phase, length <= 65_536 ? .completed : .unknown)
        }
    }

    /// 全局每轮只推进一个任务，取消关注后释放其占用。
    func testSingleDecoderAndCancellation() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try frame(Data(repeating: 32, count: 400_000)).write(to: url)
        let reader = CompressedRolloutReader()
        reader.beginCycle(ids: ["a", "b"])
        let first = reader.read(id: "a", url: url, now: now)
        XCTAssertLessThanOrEqual(first.bytes, 256 * 1_024)
        XCTAssertEqual(reader.read(id: "b", url: url, now: now).bytes, 0)
        reader.beginCycle(ids: ["b"])
        XCTAssertGreaterThan(reader.read(id: "b", url: url, now: now).bytes, 0)
    }

    /// 解码中替换文件会取消旧流，不把旧完成事件带入新文件。
    func testReplacementDuringDecode() throws {
        let url = try directory().appendingPathComponent("task.zst")
        try frame(Data(repeating: 32, count: 400_000)).write(to: url)
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
            XCTAssertEqual(reader.read(id: String(id), url: url, now: now).category, .ready)
        }
        reader.beginCycle(ids: ids)
        XCTAssertEqual(reader.read(id: "256", url: url, now: now).category, .limited)
        XCTAssertEqual(reader.read(id: "0", url: url, now: now).bytes, 0)
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
}
