import Foundation
import XCTest
import CSQLite
@testable import CodexTopCore

final class LocalCodexSourcePathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let base: URL
        let root: URL
        let outside: URL
        var database: URL { root.appendingPathComponent("state_5.sqlite") }
    }

    /// 末级链接每轮重新解析，改到目录外时不读正文，改回后恢复真实状态。
    func testLeafSymlinkRetargetsInsideOutsideInside() async throws {
        let fixture = try makeFixture()
        let first = fixture.root.appendingPathComponent("first.jsonl")
        let second = fixture.root.appendingPathComponent("second.jsonl")
        let outside = fixture.outside.appendingPathComponent("outside.jsonl")
        let link = fixture.root.appendingPathComponent("current.jsonl")
        try writeEvent("task_complete", to: first)
        try writeEvent("task_started", to: second)
        try writeEvent("task_started", to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        try addTask(path: link.path, in: fixture)
        let source = LocalCodexSource(root: fixture.root)

        let initial = try await source.snapshot(now: now)
        XCTAssertEqual(initial.tasks.first?.activity.phase, .completed)
        XCTAssertGreaterThan(initial.bytesRead, 0)
        assertResolvedPath(initial, input: link.path)

        try replaceLink(link, destination: outside)
        let escaped = try await source.snapshot(now: now)
        assertBlocked(escaped)
        assertResolvedPath(escaped, input: link.path)

        try replaceLink(link, destination: second)
        let returned = try await source.snapshot(now: now)
        XCTAssertEqual(returned.tasks.first?.activity.phase, .running)
        XCTAssertGreaterThan(returned.bytesRead, 0)
        XCTAssertNil(returned.warning)
        assertResolvedPath(returned, input: link.path)
    }

    /// 祖先目录链接改指也必须立即生效，不能复用上一轮的已解析父目录。
    func testAncestorSymlinkRetargetsInsideOutsideInside() async throws {
        let fixture = try makeFixture()
        let first = fixture.root.appendingPathComponent("first", isDirectory: true)
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        let link = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        try writeEvent("task_complete", to: first.appendingPathComponent("task.jsonl"))
        try writeEvent("task_started", to: second.appendingPathComponent("task.jsonl"))
        try writeEvent("task_started", to: fixture.outside.appendingPathComponent("task.jsonl"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let raw = link.appendingPathComponent("task.jsonl").path
        try addTask(path: raw, in: fixture)
        let source = LocalCodexSource(root: fixture.root)

        let initial = try await source.snapshot(now: now)
        XCTAssertEqual(initial.tasks.first?.activity.phase, .completed)
        try replaceLink(link, destination: fixture.outside)
        let escaped = try await source.snapshot(now: now)
        assertBlocked(escaped)
        assertResolvedPath(escaped, input: raw)
        try replaceLink(link, destination: second)
        let returned = try await source.snapshot(now: now)
        XCTAssertEqual(returned.tasks.first?.activity.phase, .running)
        XCTAssertGreaterThan(returned.bytesRead, 0)
        XCTAssertNil(returned.warning)
        assertResolvedPath(returned, input: raw)
    }

    /// 悬空链接、目标恢复及再次消失沿用未知状态和错误恢复，不缓存旧文件结果。
    func testDanglingLinkRecoversAndBecomesMissingAgain() async throws {
        let fixture = try makeFixture()
        let destination = fixture.root.appendingPathComponent("later/task.jsonl")
        let link = fixture.root.appendingPathComponent("current.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        try addTask(path: link.path, in: fixture)
        let source = LocalCodexSource(root: fixture.root)

        let missing = try await source.snapshot(now: now)
        XCTAssertEqual(missing.tasks.first?.activity.phase, .unknown)
        XCTAssertEqual(missing.bytesRead, 0)
        XCTAssertNotNil(missing.warning)
        assertResolvedPath(missing, input: link.path)
        try writeEvent("task_started", to: destination)
        let recovered = try await source.snapshot(now: now)
        XCTAssertEqual(recovered.tasks.first?.activity.phase, .running)
        XCTAssertGreaterThan(recovered.bytesRead, 0)
        XCTAssertNil(recovered.warning)
        assertResolvedPath(recovered, input: link.path)
        try FileManager.default.removeItem(at: destination)
        let missingAgain = try await source.snapshot(now: now)
        XCTAssertEqual(missingAgain.tasks.first?.activity.phase, .unknown)
        XCTAssertEqual(missingAgain.bytesRead, 0)
        XCTAssertNotNil(missingAgain.warning)
        assertResolvedPath(missingAgain, input: link.path)
    }

    /// 相对路径、Unicode、空格及链接后的上级分量均与原 Foundation 解析结果严格一致。
    func testRelativeUnicodeAndLinkedParentComponentsMatchOriginalResolution() async throws {
        let fixture = try makeFixture()
        let directory = fixture.root.appendingPathComponent("中文目录", isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let file = directory.appendingPathComponent("会话 空格 %20 #?.jsonl")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeEvent("task_complete", to: file)
        let link = fixture.root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
        let absolute = fixture.root.path + "/alias/../" + file.lastPathComponent
        let currentComponents = (FileManager.default.currentDirectoryPath as NSString).pathComponents.dropFirst().count
        let relative = String(repeating: "../", count: currentComponents) + absolute.dropFirst()
        // 相对路径及链接与上级分量的处理均以原输入的原实现为准，不先改成绝对路径。
        let originalDestination = URL(fileURLWithPath: relative).standardizedFileURL.resolvingSymlinksInPath()
        let allowedPrefix = fixture.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard originalDestination.path.hasPrefix(allowedPrefix) else {
            throw NSError(domain: "SyntheticFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "原路径解析结果不在合成目录内，拒绝写入"])
        }
        try writeEvent("task_complete", to: originalDestination)
        try addTask(path: relative, in: fixture)

        let snapshot = try await LocalCodexSource(root: fixture.root).snapshot(now: now)
        XCTAssertEqual(snapshot.tasks.first?.activity.phase, .completed)
        XCTAssertGreaterThan(snapshot.bytesRead, 0)
        XCTAssertNil(snapshot.warning)
        assertResolvedPath(snapshot, input: relative)
        XCTAssertEqual(snapshot.tasks.first?.rolloutURL.path, originalDestination.path)
    }

    /// 相同前缀的兄弟目录仍被拒绝，不能把简单字符串前缀当成目录包含关系。
    func testSiblingPrefixIsOutsideWithoutReadingItsEvent() async throws {
        let fixture = try makeFixture()
        let file = fixture.base.appendingPathComponent("root-other/event.jsonl")
        try writeEvent("task_started", to: file)
        try addTask(path: file.path, in: fixture)
        let snapshot = try await LocalCodexSource(root: fixture.root).snapshot(now: now)
        assertBlocked(snapshot)
        assertResolvedPath(snapshot, input: file.path)
    }

    /// 错把目录或循环链接登记为记录时仍给出未知，文件恢复后重新读取。
    func testDirectoryAndLinkLoopStayUnknownThenRecover() async throws {
        let fixture = try makeFixture()
        let entry = fixture.root.appendingPathComponent("event.jsonl")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try addTask(path: entry.path, in: fixture)
        let source = LocalCodexSource(root: fixture.root)
        let directory = try await source.snapshot(now: now)
        XCTAssertEqual(directory.tasks.first?.activity.phase, .unknown)
        XCTAssertEqual(directory.bytesRead, 0)
        XCTAssertNotNil(directory.warning)
        assertResolvedPath(directory, input: entry.path)
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: entry.lastPathComponent)
        let loop = try await source.snapshot(now: now)
        XCTAssertEqual(loop.tasks.first?.activity.phase, .unknown)
        XCTAssertEqual(loop.bytesRead, 0)
        XCTAssertNotNil(loop.warning)
        assertResolvedPath(loop, input: entry.path)
        try FileManager.default.removeItem(at: entry)
        try writeEvent("task_complete", to: entry)
        let recovered = try await source.snapshot(now: now)
        XCTAssertEqual(recovered.tasks.first?.activity.phase, .completed)
        XCTAssertNil(recovered.warning)
    }

    /// 创建独立合成数据库与外部对照目录，测试结束只删除该临时目录。
    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-source-path-" + UUID().uuidString)
        let fixture = Fixture(base: base, root: base.appendingPathComponent("root", isDirectory: true), outside: base.appendingPathComponent("outside", isDirectory: true))
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)", nil, nil, nil), SQLITE_OK)
        return fixture
    }

    /// 绑定原始路径字符串，确保 SQLite 不预先规范化相对路径或特殊字符。
    private func addTask(path: String, in fixture: Fixture) throws {
        var database: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO threads VALUES('synthetic','合成任务','/synthetic',?,1,2,0)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let result = path.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(result, SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    /// 只写固定类型的合成事件，不包含真实会话内容。
    private func writeEvent(_ type: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: now),
            "type": "event_msg", "payload": ["type": type, "turn_id": "synthetic-turn"]])
        data.append(10)
        try data.write(to: file)
    }

    /// 原地替换合成符号链接，模拟数据库路径字符串不变而目标发生变化。
    private func replaceLink(_ link: URL, destination: URL) throws {
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    /// 越界记录既不能透出其运行状态，也不得贡献任何读取字节。
    private func assertBlocked(_ snapshot: SourceSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.tasks.first?.activity.phase, .unknown, file: file, line: line)
        XCTAssertEqual(snapshot.tasks.first?.activity.detail, "记录位于数据目录之外，未读取", file: file, line: line)
        XCTAssertEqual(snapshot.bytesRead, 0, file: file, line: line)
        XCTAssertNotNil(snapshot.warning, file: file, line: line)
    }

    /// 比较完整 URL、目录提示和路径，不能只比较展示名称或越界布尔值。
    private func assertResolvedPath(_ snapshot: SourceSnapshot, input: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(snapshot.tasks.first?.rolloutURL.absoluteString, expected.absoluteString, file: file, line: line)
        XCTAssertEqual(snapshot.tasks.first?.rolloutURL.path, expected.path, file: file, line: line)
        XCTAssertEqual(snapshot.tasks.first?.rolloutURL.hasDirectoryPath, expected.hasDirectoryPath, file: file, line: line)
    }
}
