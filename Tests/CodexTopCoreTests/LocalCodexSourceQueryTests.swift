import XCTest
import CSQLite
@testable import CodexTopCore

final class LocalCodexSourceQueryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let schema = "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)"

    /// 通过实际快照核对清洗规则，逐字节保留换行、空白及300字素截断的旧输出。
    func testTitleCleanupPreservesUnicodeWhitespaceAndTruncation() async throws {
        let root = try fixture()
        try execute(root, schema)
        let separators = ["\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"]
        let whitespace = [" ", "\t", "\u{00A0}", "\u{2009}", "\u{3000}", "\u{FEFF}"]
        let graphemes = ["e\u{301}", "é", "👨‍👩‍👧‍👦", "🇨🇳", "👍🏽", "中"]
        var titles = ["", "普通标题", "  中间  空格  ", "甲\r\n乙", String(repeating: "👨‍👩‍👧‍👦", count: 301)]
        for separator in separators {
            titles += [separator, "甲" + separator + "乙", separator + "甲" + separator,
                       " " + separator + " 甲 " + separator + " ", String(repeating: "中", count: 299) + separator + "乙"]
        }
        for space in whitespace { titles += [space, space + "正文" + space, "甲" + space + "乙"] }
        for grapheme in graphemes {
            for count in [1, 299, 300, 301, 600] {
                titles += [String(repeating: grapheme, count: count), " " + String(repeating: grapheme, count: count) + "\t",
                           String(repeating: grapheme, count: count) + "\r\n末尾"]
            }
        }
        for (index, title) in titles.enumerated() {
            try execute(root, "INSERT INTO threads VALUES(?,?,?,?,1,2,0)",
                        ["title-\(index)", title, "/synthetic/project", root.appendingPathComponent("rollout.jsonl").path])
        }

        let snapshot = try await LocalCodexSource(root: root).snapshot(now: now)
        let actual = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0.title) })
        XCTAssertEqual(actual.count, titles.count)
        for (index, title) in titles.enumerated() {
            let cleaned = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let expected = cleaned.isEmpty ? "未命名任务" : String(cleaned.prefix(300))
            XCTAssertEqual(actual["title-\(index)"].map { Array($0.utf8) }, Array(expected.utf8), "合成标题 \(index)")
        }
        XCTAssertEqual(actual["title-0"], "未命名任务")
        XCTAssertEqual(actual["title-3"], "甲  乙")
        XCTAssertEqual(actual["title-4"], String(repeating: "👨‍👩‍👧‍👦", count: 300))
    }

    /// 提前排除普通来源不得改变旧解析器对空白、BOM、嵌套类型或异常 JSON 的判定。
    func testSourceObjectDetectionPreservesOriginalJSONSemantics() async throws {
        let root = try fixture()
        try execute(root, schema + "; ALTER TABLE threads ADD COLUMN source TEXT")
        let object = "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"parent\"}}}"
        let values: [String?] = [nil, "", "cli", "vscode", "null", "false", "123", "\"source\"", "[]", "[1]", "{}", "{", "\"{\"", "[" + object + "]", object, " \t\r\n" + object, "\u{FEFF}" + object,
            "{\"subagent\":[]}", "{\"subagent\":{\"thread_spawn\":null}}", "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":3}}}",
            "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\"}}}"]
        let path = root.appendingPathComponent("rollout.jsonl").path
        for (index, value) in values.enumerated() {
            try execute(root, "INSERT INTO threads VALUES(?,?,?,?,1,2,0,?)", ["source-\(index)", "测试", "/synthetic/project", path, value])
        }
        let snapshot = try await LocalCodexSource(root: root).snapshot(now: now)
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        XCTAssertEqual(tasks.count, values.count)
        for (index, value) in values.enumerated() {
            let original = value?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let subagent = original?["subagent"] as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            XCTAssertEqual(tasks["source-\(index)"]?.parentID, spawn?["parent_thread_id"] as? String, "source case \(index)")
        }
        XCTAssertEqual(tasks["source-14"]?.parentID, "parent")
        XCTAssertEqual(tasks["source-20"]?.parentID, "")
    }

    /// 重复路径、缺字段和特殊字符保持原 URL 显示规则，且字段更新后不会沿用上轮名称。
    func testRepeatedProjectNamesPreservePathSemanticsAcrossSnapshots() async throws {
        let root = try fixture()
        try execute(root, schema)
        let paths: [String?] = [nil, "", "/", ".", "..", "relative/project", "/synthetic/项目/", "/synthetic/a/../b", "/synthetic/a%20b", "/synthetic/空 格#问?", "/synthetic/项目/", "/synthetic//重复///", "~/project", "/synthetic/e\u{301}"]
        let rollout = root.appendingPathComponent("rollout.jsonl").path
        for (index, path) in paths.enumerated() {
            try execute(root, "INSERT INTO threads VALUES(?,?,?,?,1,2,0)", ["project-\(index)", "测试", path, rollout])
        }
        let source = LocalCodexSource(root: root)
        let first = try await source.snapshot(now: now)
        let tasks = Dictionary(uniqueKeysWithValues: first.tasks.map { ($0.id, $0) })
        for (index, path) in paths.enumerated() {
            XCTAssertEqual(tasks["project-\(index)"]?.project, URL(fileURLWithPath: path ?? "", isDirectory: true).lastPathComponent)
        }
        try execute(root, "UPDATE threads SET cwd=? WHERE id='project-10'", ["/synthetic/已移动"])
        let second = try await source.snapshot(now: now)
        XCTAssertEqual(second.tasks.first { $0.id == "project-10" }?.project, "已移动")
        XCTAssertEqual(second.tasks.first { $0.id == "project-6" }?.project, "项目")
        XCTAssertEqual(second.bytesRead, 0)
    }

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

    /// 标题和来源各自变化立即生效，即使 updated_at 没变；父子边的新增和删除每轮优先处理。
    func testLabelChangesAndParentEdgesDoNotRequireTimestampChanges() async throws {
        let root = try fixture()
        try execute(root, schema + "; ALTER TABLE threads ADD COLUMN source TEXT; CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)")
        let path = root.appendingPathComponent("rollout.jsonl").path
        let originalSource = "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"original-parent\"}}}"
        try execute(root, "INSERT INTO threads VALUES(?,?,?,?,1,2,0,?)", ["child", "  初始\n标题  ", "/synthetic/原项目/", path, originalSource])
        let source = LocalCodexSource(root: root)
        let first = try await source.snapshot(now: now)
        XCTAssertEqual(first.tasks.first?.title, "初始 标题")
        XCTAssertEqual(first.tasks.first?.parentID, "original-parent")
        let unchanged = try await source.snapshot(now: now)
        XCTAssertEqual(unchanged.tasks, first.tasks)
        XCTAssertEqual(unchanged.bytesRead, 0)

        try execute(root, "UPDATE threads SET title=?,cwd=?", ["  新\r\n标题  ", "/synthetic/新项目"])
        let renamed = try await source.snapshot(now: now)
        XCTAssertEqual(renamed.tasks.first?.title, "新  标题", "沿用原来的逐换行字符替换规则")
        XCTAssertEqual(renamed.tasks.first?.project, "新项目")
        XCTAssertEqual(renamed.tasks.first?.parentID, "original-parent")
        XCTAssertEqual(renamed.tasks.first?.updatedAt, first.tasks.first?.updatedAt)

        try execute(root, "UPDATE threads SET source=?", ["{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"new-parent\"}}}"])
        let reparented = try await source.snapshot(now: now)
        XCTAssertEqual(reparented.tasks.first?.parentID, "new-parent")
        try execute(root, "INSERT INTO thread_spawn_edges VALUES('edge-parent','child')")
        let edge = try await source.snapshot(now: now)
        XCTAssertEqual(edge.tasks.first?.parentID, "edge-parent")
        try execute(root, "DELETE FROM thread_spawn_edges")
        let fallback = try await source.snapshot(now: now)
        XCTAssertEqual(fallback.tasks.first?.parentID, "new-parent")
        try execute(root, "UPDATE threads SET title=NULL,source=NULL")
        let cleared = try await source.snapshot(now: now)
        XCTAssertEqual(cleared.tasks.first?.title, "未命名任务")
        XCTAssertNil(cleared.tasks.first?.parentID)
        XCTAssertEqual(cleared.bytesRead, 0)
    }

    /// 任务归档后重新出现及数据库版本替换，不能用旧标题或旧来源覆盖当前字段。
    func testArchivedAndReplacedDatabaseUseCurrentLabels() async throws {
        let root = try fixture()
        try execute(root, schema)
        let path = root.appendingPathComponent("rollout.jsonl").path
        try execute(root, "INSERT INTO threads VALUES(?,?,?,?,1,2,0)", ["root", "旧标题", "/synthetic/旧项目", path])
        let source = LocalCodexSource(root: root)
        _ = try await source.snapshot(now: now)
        try execute(root, "UPDATE threads SET archived=1")
        let archived = try await source.snapshot(now: now)
        XCTAssertTrue(archived.tasks.isEmpty)
        try execute(root, "UPDATE threads SET archived=0,title=?", [String(repeating: "新", count: 400)])
        let restored = try await source.snapshot(now: now)
        XCTAssertEqual(restored.tasks.first?.title, String(repeating: "新", count: 300))
        try execute(root, "UPDATE threads SET title='另一数据库'")
        try FileManager.default.copyItem(at: root.appendingPathComponent("state_5.sqlite"), to: root.appendingPathComponent("state_6.sqlite"))
        try execute(root, "UPDATE threads SET title='不该读取的旧库'")
        let replaced = try await source.snapshot(now: now)
        XCTAssertEqual(replaced.tasks.first?.title, "另一数据库")
        XCTAssertEqual(replaced.tasks.first?.activity.phase, .completed)
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
