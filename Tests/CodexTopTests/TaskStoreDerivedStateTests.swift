import XCTest
import CSQLite
import CodexTopCore
@testable import CodexTop

final class TaskStoreDerivedStateTests: XCTestCase {
    /// 排序保持状态优先、时间倒序及并列输入顺序；汇总失败优先且只计已选根任务。
    @MainActor func testSelectionOrderingAndSummaryPreserveTheirDifferentPriorities() async throws {
        let directory = try fixture()
        let store = TaskStore(stateDirectory: directory)
        await store.refresh()
        let ties = store.graph.roots.filter { $0.id.hasPrefix("running-tie-") }.map(\.id)
        XCTAssertEqual(store.selected.map(\.id), ["waiting-root", "failed", "running-new"] + ties + ["unknown", "stopped", "completed"])
        XCTAssertEqual(Set(store.active.map(\.id)), ["waiting-root", "failed", "running-new", "running-tie-a", "running-tie-b", "unknown"])
        XCTAssertEqual(store.finished.map(\.id), ["stopped", "completed"])
        XCTAssertEqual(store.statusSummary, MonitorStatusSummary(phases: [.waiting, .failed, .running, .running, .running, .unknown, .stopped, .completed]))
        XCTAssertEqual(store.statusSummary.phase, .failed, "列表先显示等待，但汇总仍以失败优先")
        XCTAssertEqual(store.runningCount, 3)
        XCTAssertEqual(store.attentionCount, 2)
        XCTAssertEqual(store.statusSummary.total, 8, "缺失编号和子任务编号不能作为额外根任务计数")
    }

    /// 不刷新数据也能立即取消和重新选择，换主题不会改变汇总，重新读取来源时仍恢复同一排序。
    @MainActor func testSelectionChangesImmediatelyWithoutRefreshOrThemeInvalidation() async throws {
        let directory = try fixture()
        let store = TaskStore(stateDirectory: directory)
        await store.refresh()
        let originalSelection = store.preferences.selectedIDs
        let originalOrder = store.selected.map(\.id)
        let originalSummary = store.statusSummary
        let refreshedAt = store.lastRefresh

        store.applySelection(["completed"], original: originalSelection)
        XCTAssertEqual(store.selected.map(\.id), ["completed"])
        XCTAssertTrue(store.active.isEmpty)
        XCTAssertEqual(store.finished.map(\.id), ["completed"])
        XCTAssertEqual(store.statusSummary, MonitorStatusSummary(phases: [.completed]))
        store.setTheme(.light)
        XCTAssertEqual(store.statusSummary.phase, .completed)
        store.applySelection([], original: ["completed"])
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertEqual(store.statusSummary, MonitorStatusSummary(phases: []))
        store.applySelection(originalSelection, original: [])
        XCTAssertEqual(store.lastRefresh, refreshedAt)
        XCTAssertEqual(store.selected.map(\.id), originalOrder)
        XCTAssertEqual(store.statusSummary, originalSummary)

        await store.refresh()
        XCTAssertEqual(store.selected.map(\.id), originalOrder)
        XCTAssertEqual(store.statusSummary, originalSummary)
    }

    /// 用合成数据库覆盖父子等待、失败、运行并列、未知和终态，不连接真实桌面或账号。
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("derived-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "SyntheticDerivedState", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticDerivedState", code: 2)
        }
        let now = Date()
        let rows: [(String, String, TimeInterval)] = [("waiting-root", "task_complete", -90), ("waiting-child", "exec_approval_request", -5),
            ("failed", "task_failed", -40), ("running-new", "task_started", -10), ("running-tie-a", "task_started", -20),
            ("running-tie-b", "task_started", -20), ("unknown", "synthetic_unrecognized", -3),
            ("stopped", "turn_aborted", -30), ("completed", "task_complete", -50), ("unselected", "task_started", -1)]
        for (id, type, delta) in rows {
            let log = directory.appendingPathComponent(id + ".jsonl")
            let at = now.addingTimeInterval(delta)
            let event: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: at),
                                       "payload": ["type": type, "turn_id": "synthetic-turn"]]
            try (JSONSerialization.data(withJSONObject: event) + Data([10])).write(to: log)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO threads VALUES(?,?,?, ?,?,?,0)", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "SyntheticDerivedState", code: 3)
            }
            defer { sqlite3_finalize(statement) }
            for (index, value) in [id, "合成任务", "/synthetic", log.path].enumerated() {
                guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                    throw NSError(domain: "SyntheticDerivedState", code: 4)
                }
            }
            sqlite3_bind_int64(statement, 5, Int64(at.timeIntervalSince1970))
            sqlite3_bind_int64(statement, 6, Int64(at.timeIntervalSince1970))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "SyntheticDerivedState", code: 5) }
        }
        guard sqlite3_exec(database, "INSERT INTO thread_spawn_edges VALUES('waiting-root','waiting-child')", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticDerivedState", code: 6)
        }
        var preferences = MonitorPreferences()
        preferences.codexHome = directory.path
        preferences.initialized = true
        preferences.autoMonitor = false
        preferences.autoBaselineIDs = Set(rows.map { $0.0 })
        preferences.selectedIDs = Set(rows.map { $0.0 }).subtracting(["unselected"]).union(["missing-id"])
        try PreferencesFile(url: directory.appendingPathComponent("preferences.json")).save(preferences)
        return directory
    }
}
