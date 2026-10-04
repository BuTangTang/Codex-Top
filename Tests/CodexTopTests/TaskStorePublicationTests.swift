import Combine
import XCTest
import CSQLite
import CodexTopCore
@testable import CodexTop

final class TaskStorePublicationTests: XCTestCase {
    /// 相同文件仍参与刷新，但不得广播整个数据仓库或触发窗口重排，刷新按钮仍接收忙碌状态。
    @MainActor func testUnchangedRefreshOnlyPublishesBusyTransitions() async throws {
        let directory = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(stateDirectory: directory)
        await store.refresh()
        let firstRefresh = store.lastRefresh
        var updates = 0, layoutUpdates = 0, storeUpdates = 0
        var busy: [Bool] = []
        var subscriptions = Set<AnyCancellable>()
        store.objectWillChange.sink { storeUpdates += 1 }.store(in: &subscriptions)
        store.$tasks.dropFirst().sink { _ in updates += 1 }.store(in: &subscriptions)
        store.$graph.dropFirst().sink { _ in updates += 1 }.store(in: &subscriptions)
        store.$preferences.dropFirst().sink { _ in updates += 1 }.store(in: &subscriptions)
        store.$historicalQuota.dropFirst().sink { _ in updates += 1 }.store(in: &subscriptions)
        store.$quota.dropFirst().sink { _ in updates += 1 }.store(in: &subscriptions)
        store.$sourceWarning.dropFirst().sink { _ in updates += 1 }.store(in: &subscriptions)
        store.$loading.dropFirst().sink { _ in updates += 1 }.store(in: &subscriptions)
        store.refreshState.$isRefreshing.dropFirst().sink { busy.append($0) }.store(in: &subscriptions)
        store.onChange = { layoutUpdates += 1 }

        await store.refresh()

        XCTAssertEqual(updates, 0)
        XCTAssertEqual(storeUpdates, 0, "后台检查的忙碌切换不能唤醒圆环和隐藏任务列表")
        XCTAssertEqual(layoutUpdates, 0)
        XCTAssertEqual(busy, [true, false])
        XCTAssertGreaterThan(try XCTUnwrap(store.lastRefresh), try XCTUnwrap(firstRefresh))
        XCTAssertEqual(store.runningCount, 1)
        withExtendedLifetime(subscriptions) {}
    }

    /// 新完成事件及数据源丢失仍立即发布；相同失败不反复重排，恢复后重新显示真实状态。
    @MainActor func testChangedRecordAndSourceRecoveryStillUpdate() async throws {
        let directory = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(stateDirectory: directory)
        await store.refresh()
        var layoutUpdates = 0
        var busy: [Bool] = []
        let subscription = store.refreshState.$isRefreshing.dropFirst().sink { busy.append($0) }
        store.onChange = { layoutUpdates += 1 }
        let log = directory.appendingPathComponent("task.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: event("task_complete"))
        try handle.close()
        await store.refresh()
        XCTAssertEqual(store.selected.first?.activity.phase, .completed)
        XCTAssertEqual(store.completionSequence, 1)
        XCTAssertEqual(layoutUpdates, 1)

        let database = directory.appendingPathComponent("state_5.sqlite")
        let backup = directory.appendingPathComponent("synthetic-backup.sqlite")
        try FileManager.default.moveItem(at: database, to: backup)
        await store.refresh()
        XCTAssertEqual(store.selected.first?.activity.phase, .unknown)
        XCTAssertNotNil(store.sourceWarning)
        let afterFailure = layoutUpdates
        await store.refresh()
        XCTAssertEqual(layoutUpdates, afterFailure)
        try FileManager.default.moveItem(at: backup, to: database)
        await store.refresh()
        XCTAssertEqual(store.selected.first?.activity.phase, .completed)
        XCTAssertNil(store.sourceWarning)
        XCTAssertGreaterThan(layoutUpdates, afterFailure)
        XCTAssertEqual(busy, [true, false, true, false, true, false, true, false])
        XCTAssertFalse(store.refreshing, "数据源失败及恢复后仍须解除刷新按钮的忙碌禁用")
        withExtendedLifetime(subscription) {}
    }

    /// 子任务从等待进入终态后，本轮过期判断必须读取新图，不能沿用刷新前的等待状态。
    @MainActor func testRetentionUsesUpdatedChildGraphInSameRefresh() async throws {
        let directory = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-8 * 86_400)
        let childLog = directory.appendingPathComponent("child.jsonl")
        try event("task_complete", at: old).write(to: directory.appendingPathComponent("task.jsonl"))
        try event("exec_approval_request", at: old).write(to: childLog)
        var connection: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &connection) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(connection) }
        let timestamp = Int(old.timeIntervalSince1970)
        let sql = """
        UPDATE threads SET created_at=\(timestamp),updated_at=\(timestamp);
        INSERT INTO threads VALUES('child','合成子任务','/synthetic','\(childLog.path)',\(timestamp),\(timestamp),0);
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT);
        INSERT INTO thread_spawn_edges VALUES('synthetic','child');
        """
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
        let store = TaskStore(stateDirectory: directory)
        await store.refresh()
        XCTAssertEqual(store.preferences.selectedIDs, ["synthetic"])
        XCTAssertEqual(store.graph.activity(for: try XCTUnwrap(store.graph.roots.first)).phase, .waiting)

        let handle = try FileHandle(forWritingTo: childLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: event("turn_aborted", at: old))
        try handle.close()
        await store.refresh()

        XCTAssertEqual(store.tasks.first(where: { $0.id == "child" })?.activity.phase, .stopped)
        XCTAssertTrue(store.preferences.selectedIDs.isEmpty)
        XCTAssertEqual(store.preferences.automaticallyRemovedIDs, ["synthetic"])
    }

    /// 使用独立临时数据库与合成事件，不接触真实任务或账号。
    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)", nil, nil, nil), SQLITE_OK)
        let log = directory.appendingPathComponent("task.jsonl")
        try event("task_started").write(to: log)
        let now = Int(Date().timeIntervalSince1970)
        let sql = "INSERT INTO threads VALUES('synthetic','合成任务','/synthetic','\(log.path)',\(now),\(now),0)"
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
        var preferences = MonitorPreferences()
        preferences.codexHome = directory.path
        preferences.selectedIDs = ["synthetic"]
        preferences.initialized = true
        preferences.autoBaselineIDs = ["synthetic"]
        try PreferencesFile(url: directory.appendingPathComponent("preferences.json")).save(preferences)
        return directory
    }

    /// 按用例时间生成当前轮次的完整事件行，保留真实解析和状态转换路径。
    private func event(_ type: String, at time: Date = Date()) throws -> Data {
        let record: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: time),
                                   "payload": ["type": type, "turn_id": "synthetic-turn"]]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(10)
        return data
    }
}
