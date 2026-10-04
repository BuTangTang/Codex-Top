import XCTest
import CSQLite
@testable import CodexTopCore

final class LocalCodexSourceQueryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let schema = "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)"

    /// 多行读取保持列别名和原索引，前面列的 NULL 不得错位或污染后续行。
    func testAliasesNullColumnsAndMultipleRowsKeepTheirOwnValues() async throws {
        let root = try fixture()
        try execute(root, schema + "; ALTER TABLE threads ADD COLUMN name TEXT; ALTER TABLE threads ADD COLUMN source TEXT")
        let path = root.appendingPathComponent("rollout.jsonl").path
        let insert = "INSERT INTO threads VALUES(?,?,?,?,1,2,0,?,?)"
        try execute(root, insert, ["root", "原始标题", "/synthetic/根项目", path, nil, nil])
        try execute(root, insert, ["child", "被别名覆盖", nil, path, "重命名标题", "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"root\"}}}"])
        try execute(root, insert, ["empty-name", "空名称回退", "/synthetic/空名称", path, "", nil])
        try execute(root, insert, ["null-title", nil, "/synthetic/标题为空", path, nil, nil])
        try execute(root, insert, [nil, "缺少编号", "/synthetic/不可见", path, nil, nil])
        try execute(root, insert, ["null-path", "缺少路径", "/synthetic/不可见", nil, nil, nil])
        let database = root.appendingPathComponent("state_5.sqlite")
        let original = try Data(contentsOf: database)

        let snapshot = try await LocalCodexSource(root: root).snapshot(now: now)

        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        XCTAssertEqual(Set(tasks.keys), ["root", "child", "empty-name", "null-title"])
        XCTAssertEqual(tasks["root"]?.title, "原始标题")
        XCTAssertEqual(tasks["root"]?.project, "根项目")
        XCTAssertNil(tasks["root"]?.parentID)
        XCTAssertEqual(tasks["child"]?.title, "重命名标题")
        XCTAssertEqual(tasks["child"]?.parentID, "root")
        XCTAssertEqual(tasks["empty-name"]?.title, "空名称回退")
        XCTAssertEqual(tasks["empty-name"]?.project, "空名称")
        XCTAssertEqual(tasks["null-title"]?.title, "未命名任务")
        XCTAssertEqual(tasks["null-title"]?.project, "标题为空")
        XCTAssertTrue(tasks.values.allSatisfy { $0.activity.phase == .completed })
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(try Data(contentsOf: database), original)
    }

    /// 同一源依次读取空表、增补可选列及移除可选列，不得复用上一条查询或上一轮的列布局。
    func testEmptyResultsAndSchemaChangesAreReadAgainOnSameSource() async throws {
        let root = try fixture()
        try execute(root, schema)
        let source = LocalCodexSource(root: root)
        let empty = try await source.snapshot(now: now)
        XCTAssertTrue(empty.tasks.isEmpty)
        let path = root.appendingPathComponent("rollout.jsonl").path
        try execute(root, "INSERT INTO threads VALUES(?,?,?,?,1,2,0)", ["root", "原始标题", "/synthetic/项目", path])
        let original = try await source.snapshot(now: now)
        XCTAssertEqual(original.tasks.first?.title, "原始标题")
        XCTAssertNil(original.tasks.first?.parentID)

        try execute(root, "ALTER TABLE threads ADD COLUMN name TEXT; ALTER TABLE threads ADD COLUMN source TEXT")
        try execute(root, "UPDATE threads SET name=?,source=?", ["新增名称", "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"new-parent\"}}}"])
        let extended = try await source.snapshot(now: now)
        XCTAssertEqual(extended.tasks.first?.title, "新增名称")
        XCTAssertEqual(extended.tasks.first?.parentID, "new-parent")

        try execute(root, """
        BEGIN;
        ALTER TABLE threads RENAME TO old_threads;
        \(schema);
        INSERT INTO threads SELECT id,title,cwd,rollout_path,created_at,updated_at,archived FROM old_threads;
        DROP TABLE old_threads;
        COMMIT;
        """)
        let restored = try await source.snapshot(now: now)
        XCTAssertEqual(restored.tasks.first?.title, "原始标题")
        XCTAssertNil(restored.tasks.first?.parentID)
        XCTAssertEqual(restored.tasks.first?.activity.phase, .completed)
        XCTAssertEqual(restored.bytesRead, 0, "字段变化不得迫使未变化的历史重新读取")
    }

    /// 独立临时目录仅包含合成数据库和一条完成事件，结束后自动移除。
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let record: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
                                    "payload": ["type": "task_complete", "turn_id": "synthetic-turn"]]
        try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: root.appendingPathComponent("rollout.jsonl"))
        return root
    }

    /// 只为夹具写库；有参数时按位置绑定 NULL，避免路径与测试文本参与 SQL 拼接。
    private func execute(_ root: URL, _ sql: String, _ values: [String?] = []) throws {
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "SyntheticQueryFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        if values.isEmpty {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "SyntheticQueryFixture", code: 2) }
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "SyntheticQueryFixture", code: 3) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard result == SQLITE_OK else { throw NSError(domain: "SyntheticQueryFixture", code: 4) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "SyntheticQueryFixture", code: 5) }
    }
}
