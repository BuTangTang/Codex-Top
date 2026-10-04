import XCTest
import CSQLite
@testable import CodexTopCore

final class LocalCodexSourceQueryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let schema = "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)"

    /// 超过缓存容量的历史仍使用当前字段；长标题、父关系切换与归档后恢复不复活旧标签。
    func testLargeHistoryLabelsStayCurrentAcrossReplacementAndArchive() async throws {
        let root = try fixture()
        try execute(root, schema + "; ALTER TABLE threads ADD COLUMN source TEXT")
        let path = root.appendingPathComponent("rollout.jsonl").path
        try execute(root, """
        WITH RECURSIVE numbers(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM numbers WHERE n<2199)
        INSERT INTO threads SELECT printf('cache-%04d',n),'合成标题 ' || n,'/synthetic/project',?,1,n,0,?
        FROM numbers
        """, [path, "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"old-parent\"}}}"])
        let source = LocalCodexSource(root: root)
        let initial = try await source.snapshot(now: now)
        XCTAssertEqual(initial.tasks.count, 2_200)
        XCTAssertTrue(initial.tasks.allSatisfy { $0.parentID == "old-parent" && $0.activity.phase == .completed })
        let repeated = try await source.snapshot(now: now)
        XCTAssertEqual(repeated.tasks, initial.tasks)
        XCTAssertEqual(repeated.bytesRead, 0)

        let longTitle = String(repeating: "改🙂", count: 900)
        try execute(root, "UPDATE threads SET title=?,source=NULL", [longTitle])
        let replaced = try await source.snapshot(now: now)
        XCTAssertEqual(replaced.tasks.count, 2_200)
        XCTAssertTrue(replaced.tasks.allSatisfy { $0.title == String(longTitle.prefix(300)) && $0.parentID == nil })
        XCTAssertEqual(replaced.bytesRead, 0)
        try execute(root, "UPDATE threads SET archived=1 WHERE id<'cache-2100'")
        try execute(root, "UPDATE threads SET title='短标题',source=?", ["{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"new-parent\"}}}"])
        let archived = try await source.snapshot(now: now)
        XCTAssertEqual(archived.tasks.count, 100)
        XCTAssertTrue(archived.tasks.allSatisfy { $0.title == "短标题" && $0.parentID == "new-parent" })
        try execute(root, "UPDATE threads SET archived=0")
        let restored = try await source.snapshot(now: now)
        XCTAssertEqual(restored.tasks.count, 2_200)
        XCTAssertTrue(restored.tasks.allSatisfy { $0.title == "短标题" && $0.parentID == "new-parent" && $0.activity.phase == .completed })
        XCTAssertNil(restored.warning)
    }

    /// SQLite 各存储类型仍先转 C 字符串；日期不改用 SQLite 数值转换，内嵌 NUL 继续在原边界截断。
    func testMainRowsPreserveStorageClassesDatesAndEmbeddedNUL() async throws {
        let root = try fixture()
        try execute(root, "CREATE TABLE threads(id,title,cwd,rollout_path,created_at,updated_at,archived,source)")
        let path = root.appendingPathComponent("rollout.jsonl").path
        let values: [(expression: String, expected: Double)] = [
            ("NULL", 0), ("''", 0), ("'invalid'", 0), ("17", 17), ("17.25", 17.25),
            ("'2e3'", 2_000), ("'-23.75'", -23.75), ("'0x1p4'", 16),
            ("X'34322E35003939'", 42.5), ("X'FF'", 0), ("'7' || char(0) || '99'", 7)
        ]
        for (index, value) in values.enumerated() {
            try execute(root, "INSERT INTO threads VALUES(?,123,456,?,\(value.expression),\(value.expression),0,NULL)",
                        ["storage-\(index)", path])
        }
        try execute(root, """
        INSERT INTO threads VALUES('nul-id' || char(0) || 'ignored',X'41FF420043',
        '/synthetic/project' || char(0) || 'ignored',? || char(0) || '/not-a-file',1,2,0,
        '{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}' || char(0) || 'ignored')
        """, [path])
        let storedTypes = try readValues(root, "SELECT typeof(created_at) FROM threads WHERE id IN ('storage-0','storage-3','storage-4','storage-5','storage-8') ORDER BY id")
        XCTAssertEqual(storedTypes.map { $0[0] }, ["null", "integer", "real", "text", "blob"])

        let snapshot = try await LocalCodexSource(root: root).snapshot(now: now)
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        XCTAssertEqual(tasks.count, values.count + 1)
        for (index, value) in values.enumerated() {
            let task = try XCTUnwrap(tasks["storage-\(index)"])
            XCTAssertEqual(task.createdAt.timeIntervalSince1970, value.expected, accuracy: 0.000_001)
            XCTAssertEqual(task.updatedAt.timeIntervalSince1970, value.expected, accuracy: 0.000_001)
            XCTAssertEqual(task.title, "123")
            XCTAssertEqual(task.project, "456")
        }
        let embeddedNUL = try XCTUnwrap(tasks["nul-id"])
        XCTAssertEqual(embeddedNUL.title, "A\u{FFFD}B")
        XCTAssertEqual(embeddedNUL.project, "project")
        XCTAssertEqual(embeddedNUL.parentID, "parent")
        XCTAssertEqual(embeddedNUL.rolloutURL, URL(fileURLWithPath: path, isDirectory: false).resolvingSymlinksInPath())
        XCTAssertTrue(tasks.values.allSatisfy { $0.activity.phase == .completed })
        XCTAssertNil(snapshot.warning)
    }

    /// 任务顺序由当轮 SQL 决定；建立排序索引后也不添加自定义并列排序，NULL 编号与路径继续过滤。
    func testMainRowsKeepSQLiteOrderingAcrossIndexChanges() async throws {
        let root = try fixture()
        try execute(root, schema)
        let path = root.appendingPathComponent("rollout.jsonl").path
        for (id, updated) in [("low", "1"), ("tie-z", "10"), ("high", "30"), ("tie-a", "10"), ("tie-m", "10"), ("null-time", "NULL")] {
            try execute(root, "INSERT INTO threads VALUES(?,?,?, ?,1,\(updated),0)", [id, id, "/synthetic/project", path])
        }
        try execute(root, "INSERT INTO threads VALUES(NULL,'missing id','/synthetic/project',?,1,100,0)", [path])
        try execute(root, "INSERT INTO threads VALUES('missing-path','missing path','/synthetic/project',NULL,1,100,0)")
        try execute(root, "INSERT INTO threads VALUES('archived','archived','/synthetic/project',?,1,1000,1)", [path])
        let source = LocalCodexSource(root: root)
        for indexed in [false, true] {
            if indexed { try execute(root, "CREATE INDEX threads_updated_idx ON threads(updated_at)") }
            let expected = try readValues(root, "SELECT id,title,cwd,rollout_path,created_at,updated_at,'' AS source FROM threads WHERE archived=0 ORDER BY updated_at DESC")
                .compactMap { row in row[3] == nil ? nil : row[0] }
            let snapshot = try await source.snapshot(now: now)
            XCTAssertEqual(snapshot.tasks.map(\.id), expected)
            XCTAssertEqual(snapshot.tasks.first?.id, "high")
            XCTAssertEqual(snapshot.tasks.last?.id, "null-time")
            XCTAssertEqual(Set(snapshot.tasks.dropFirst().dropLast().map(\.id)), ["tie-z", "tie-a", "tie-m", "low"])
            if indexed { XCTAssertEqual(snapshot.bytesRead, 0) }
        }
    }

    /// 分别触发主 SELECT 的 prepare 与 step 失败；修复合成 schema 后同一源必须重新读取并恢复。
    func testMainQueryPrepareAndStepFailuresRecoverOnSameSource() async throws {
        let root = try fixture()
        try execute(root, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at TEXT COLLATE synthetic_order,archived INTEGER)", customCollation: true)
        let path = root.appendingPathComponent("rollout.jsonl").path
        try execute(root, "INSERT INTO threads VALUES('root','测试','/synthetic/project',?,1,2,0)", [path], customCollation: true)
        XCTAssertEqual(try readValues(root, "PRAGMA table_info(threads)").compactMap { $0[1] },
                       ["id", "title", "cwd", "rollout_path", "created_at", "updated_at", "archived"])
        let source = LocalCodexSource(root: root)
        do {
            _ = try await source.snapshot(now: now)
            XCTFail("主查询缺少排序规则时必须报告 prepare 失败")
        } catch {
            guard case CodexSourceError.incompatibleDatabase = error else { return XCTFail("错误分类改变：\(error)") }
        }
        try execute(root, "DROP TABLE threads; \(schema)")
        try execute(root, "INSERT INTO threads VALUES('root','已恢复','/synthetic/project',?,1,2,0)", [path])
        let recovered = try await source.snapshot(now: now)
        XCTAssertEqual(recovered.tasks.first?.title, "已恢复")

        try execute(root, """
        ALTER TABLE threads RENAME TO backing_threads;
        CREATE VIEW threads AS SELECT id,title,cwd,rollout_path,created_at,
        abs(-9223372036854775808) AS updated_at,archived FROM backing_threads;
        """)
        XCTAssertEqual(try readValues(root, "PRAGMA table_info(threads)").compactMap { $0[1] },
                       ["id", "title", "cwd", "rollout_path", "created_at", "updated_at", "archived"])
        do {
            _ = try await source.snapshot(now: now)
            XCTFail("主查询整数溢出时必须报告 step 失败")
        } catch {
            guard case CodexSourceError.databaseUnavailable = error else { return XCTFail("错误分类改变：\(error)") }
        }
        try execute(root, "DROP VIEW threads; ALTER TABLE backing_threads RENAME TO threads")
        let restored = try await source.snapshot(now: now)
        XCTAssertEqual(restored.tasks, recovered.tasks)
        XCTAssertEqual(restored.bytesRead, 0)
    }

    /// 边表结构错误只影响可选父子边；来源回退和边表修复继续逐轮生效。
    func testMalformedEdgeTableFallsBackAndRecoversOnSameSource() async throws {
        let root = try fixture()
        try execute(root, schema + "; ALTER TABLE threads ADD COLUMN source TEXT; CREATE TABLE thread_spawn_edges(unrelated TEXT)")
        let path = root.appendingPathComponent("rollout.jsonl").path
        try execute(root, "INSERT INTO threads VALUES('child','测试','/synthetic/project',?,1,2,0,?)",
                    [path, "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"source-parent\"}}}"])
        let source = LocalCodexSource(root: root)
        let fallback = try await source.snapshot(now: now)
        XCTAssertEqual(fallback.tasks.first?.parentID, "source-parent")
        XCTAssertNil(fallback.warning)
        try execute(root, """
        DROP TABLE thread_spawn_edges;
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT);
        INSERT INTO thread_spawn_edges VALUES('edge-parent','child'),(NULL,'child'),('ignored',NULL);
        """)
        let repaired = try await source.snapshot(now: now)
        XCTAssertEqual(repaired.tasks.first?.parentID, "edge-parent")
        XCTAssertEqual(repaired.bytesRead, 0)
        try execute(root, "ALTER TABLE thread_spawn_edges RENAME COLUMN parent_thread_id TO unrelated")
        let brokenAgain = try await source.snapshot(now: now)
        XCTAssertEqual(brokenAgain.tasks.first?.parentID, "source-parent")
        XCTAssertNil(brokenAgain.warning)
        XCTAssertEqual(brokenAgain.bytesRead, 0)
    }

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
    private func execute(_ root: URL, _ sql: String, _ values: [String?] = [], customCollation: Bool = false) throws {
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "SyntheticQueryFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        if customCollation {
            // 仅写夹具时注册；正式只读连接没有此排序规则，可真实触发主查询 prepare 失败。
            guard sqlite3_create_collation(database, "synthetic_order", SQLITE_UTF8, nil, { _, _, _, _, _ in 0 }) == SQLITE_OK else {
                throw NSError(domain: "SyntheticQueryFixture", code: 6)
            }
        }
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

    /// 独立只读 SQL 给出 SQLite 的顺序和存储事实，不依赖生产行结构或默认值处理。
    private func readValues(_ root: URL, _ sql: String) throws -> [[String?]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("state_5.sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "SyntheticQueryFixture", code: 7)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "SyntheticQueryFixture", code: 8) }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw NSError(domain: "SyntheticQueryFixture", code: 9) }
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
    }
}
