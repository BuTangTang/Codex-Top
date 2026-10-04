import Foundation
import Darwin
import XCTest
@testable import CodexTopCore

final class IncrementalRolloutMetadataTests: XCTestCase {
    private let seconds = 1_800_000_000

    /// 为每个场景创建独立合成目录，测试结束后清除。
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// 生成等长事件，确保重写场景不能靠文件大小变化通过。
    private func event(_ type: String, turn: String = "fixture") throws -> Data {
        let record: [String: Any] = ["timestamp": "2027-01-15T08:00:00Z", "type": "event_msg",
                                     "payload": ["type": type, "turn_id": turn]]
        let json = try JSONSerialization.data(withJSONObject: record)
        XCTAssertLessThan(json.count, 255)
        return json + Data(repeating: 32, count: 255 - json.count) + Data([10])
    }

    /// 原地覆盖并调整长度，以保留 inode 来单独检验时间和截断判断。
    private func overwrite(_ data: Data, at file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
    }

    /// 追加数据，检验已读偏移与未结束行不被元数据优化改变。
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// 直接设定纳秒修改时间，避免 Date 浮点转换掩盖等长重写。
    private func setModified(_ file: URL, nanoseconds: Int) throws {
        var values = [timespec(tv_sec: seconds, tv_nsec: nanoseconds), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        let result = file.path.withCString { utimensat(AT_FDCWD, $0, &values, 0) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let actual = try metadata(file)
        guard actual.st_mtimespec.tv_nsec == nanoseconds else { throw XCTSkip("合成目录的文件系统未保留纳秒修改时间") }
    }

    /// 独立读取链接自身的元数据，用于核对合成文件条件。
    private func metadata(_ file: URL) throws -> stat {
        var value = stat()
        let result = file.path.withCString { lstat($0, &value) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }

    /// 未变文件不重读，追加事件仍从原游标读取。
    func testUnchangedFileAndAppendPreserveIncrementalCursor() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        let first = try event("task_started")
        try first.write(to: file)
        var reader = IncrementalRollout()
        XCTAssertEqual(try reader.refresh(url: file), first.count)
        XCTAssertEqual(try reader.refresh(url: file), 0)
        let completion = try event("task_complete")
        try append(completion, to: file)
        XCTAssertEqual(try reader.refresh(url: file), completion.count)
        XCTAssertEqual(reader.reducer.activity.phase, .completed)
        XCTAssertEqual(reader.offset, UInt64(first.count + completion.count))
        XCTAssertTrue(reader.isCaughtUp)
        XCTAssertEqual(try reader.refresh(url: file), 0)
    }

    /// 同 inode、同尺寸、同一秒内仅一纳秒差异的重写也必须清除旧轮状态。
    func testSameSizeRewritePreservesNanosecondPrecision() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        try event("task_started", turn: "old").write(to: file)
        try setModified(file, nanoseconds: 125_000_000)
        let before = try metadata(file)
        var reader = IncrementalRollout()
        _ = try reader.refresh(url: file)
        try overwrite(event("task_complete", turn: "new"), at: file)
        try setModified(file, nanoseconds: 125_000_001)
        let after = try metadata(file)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(try reader.refresh(url: file), Int(after.st_size))
        XCTAssertEqual(reader.reducer.activity.phase, .completed)
        XCTAssertNil(reader.reducer.activity.startedAt)
        XCTAssertNotEqual(reader.reducer.activity.turnID, "old")
        XCTAssertEqual(try reader.refresh(url: file), 0)
    }

    /// 等长且时间相同的轮转仍由 inode 变化识别。
    func testReplacementWithSameSizeAndTimestampDiscardsOldState() throws {
        let root = try directory(), file = root.appendingPathComponent("rollout.jsonl")
        try event("task_started", turn: "old").write(to: file)
        try setModified(file, nanoseconds: 250_000_000)
        let before = try metadata(file)
        var reader = IncrementalRollout()
        _ = try reader.refresh(url: file)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("rotated.jsonl"))
        try event("task_complete", turn: "new").write(to: file)
        try setModified(file, nanoseconds: 250_000_000)
        let after = try metadata(file)
        XCTAssertNotEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(try reader.refresh(url: file), Int(after.st_size))
        XCTAssertEqual(reader.reducer.activity.phase, .completed)
        XCTAssertNil(reader.reducer.activity.startedAt)
    }

    /// 截断必须同时清除旧活动和尚未结束的行，随后追加继续正常处理。
    func testTruncationClearsPendingPartialLine() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        try (event("task_started") + event("task_complete").prefix(80)).write(to: file)
        let before = try metadata(file)
        var reader = IncrementalRollout()
        _ = try reader.refresh(url: file)
        XCTAssertEqual(reader.reducer.activity.phase, .running)
        try overwrite(event("task_failed"), at: file)
        XCTAssertEqual(try metadata(file).st_ino, before.st_ino)
        XCTAssertEqual(try reader.refresh(url: file), 256)
        XCTAssertEqual(reader.reducer.activity.phase, .failed)
        try append(event("user_message"), to: file)
        XCTAssertEqual(try reader.refresh(url: file), 256)
        XCTAssertEqual(reader.reducer.activity.phase, .running)
    }

    /// 路径消失保留 Foundation 的失败信息，不能把失败当作空文件或损坏原游标。
    func testMissingFilePreservesFoundationErrorAndReaderCanRecover() throws {
        let root = try directory(), file = root.appendingPathComponent("rollout.jsonl")
        try event("task_started").write(to: file)
        var reader = IncrementalRollout()
        _ = try reader.refresh(url: file)
        let previous = reader.reducer.activity, offset = reader.offset
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("old.jsonl"))
        XCTAssertThrowsError(try reader.refresh(url: file)) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, NSFileReadNoSuchFileError)
        }
        XCTAssertEqual(reader.reducer.activity, previous)
        XCTAssertEqual(reader.offset, offset)
        try event("task_complete").write(to: file)
        XCTAssertEqual(try reader.refresh(url: file), 256)
        XCTAssertEqual(reader.reducer.activity.phase, .completed)
    }

    /// 与原 Foundation 行为一致，末级符号链接只提供链接自身元数据，不能改为跟随目标。
    func testSymbolicLinkMetadataDoesNotFollowTarget() throws {
        let root = try directory(), target = root.appendingPathComponent("target.jsonl"), link = root.appendingPathComponent("link.jsonl")
        try event("task_started").write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.jsonl")
        let original = try FileManager.default.attributesOfItem(atPath: link.path)
        let linkSize = try XCTUnwrap((original[.size] as? NSNumber)?.intValue)
        XCTAssertEqual(linkSize, "target.jsonl".utf8.count)
        XCTAssertEqual(try metadata(link).st_ino, (original[.systemFileNumber] as? NSNumber)?.uint64Value)
        var reader = IncrementalRollout()
        XCTAssertEqual(try reader.refresh(url: link), linkSize)
        XCTAssertEqual(reader.offset, UInt64(linkSize))
        XCTAssertEqual(reader.reducer.activity.phase, .unknown)
        try append(event("task_complete"), to: target)
        XCTAssertEqual(try reader.refresh(url: link), 0, "目标文件变动不能变成链接自身元数据变动")
    }

    /// 断开的链接仍能读取其元数据，但新读者打开目标时必须报告原读取失败。
    func testDanglingSymbolicLinkStillFailsWhenOpeningTarget() throws {
        let root = try directory(), link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing.jsonl")
        XCTAssertNoThrow(try FileManager.default.attributesOfItem(atPath: link.path))
        var reader = IncrementalRollout()
        XCTAssertThrowsError(try reader.refresh(url: link))
        XCTAssertEqual(reader.offset, 0)
        XCTAssertFalse(reader.isCaughtUp)
    }

    /// 开始时间回查前若发生纳秒级等长重写，不能把旧游标的历史补入新文件。
    func testRecoveryRejectsSameSizeRewriteSinceRefresh() throws {
        let file = try directory().appendingPathComponent("rollout.jsonl")
        let data = try event("task_started") + Data(repeating: 120, count: 8_192) + Data([10]) + event("agent_message")
        try data.write(to: file)
        try setModified(file, nanoseconds: 500_000_000)
        var reader = IncrementalRollout(maximumRead: 1_024)
        XCTAssertEqual(try reader.refresh(url: file), 1_024)
        XCTAssertEqual(reader.reducer.activity.phase, .running)
        XCTAssertNil(reader.reducer.activity.startedAt)
        let original = reader.reducer.activity, offset = reader.offset
        try setModified(file, nanoseconds: 500_000_001)
        XCTAssertEqual(try reader.recoverTiming(url: file), 0)
        XCTAssertEqual(reader.reducer.activity, original)
        XCTAssertEqual(reader.offset, offset)
        _ = try reader.refresh(url: file)
        XCTAssertGreaterThan(try reader.recoverTiming(url: file), 0)
        XCTAssertNotNil(reader.reducer.activity.startedAt)
        XCTAssertEqual(reader.offset, offset)
    }
}
