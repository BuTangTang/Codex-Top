import XCTest
import Foundation
import CSQLite
@testable import CodexTopCore

final class CoreTests: XCTestCase {
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ type: String, at: Date? = nil, extra: [String: Any] = [:], kind: String = "event_msg") -> Data {
        var payload = extra; payload["type"] = type
        return try! JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: at ?? time), "type": kind, "payload": payload])
    }
    func task(_ id: String, phase: TaskPhase = .idle, createdAt: Date? = nil, parent: String? = nil) -> CodexTask {
        var task = CodexTask(id: id, title: id, project: "Sample", createdAt: createdAt ?? time.addingTimeInterval(-100), updatedAt: time, parentID: parent, rolloutURL: URL(fileURLWithPath: "/tmp/fixture.jsonl"))
        task.activity = TaskActivity(phase: phase)
        return task
    }
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testLifecycleResumeAndLateCompletion() {
        var reducer = RolloutReducer()
        reducer.consume(event("task_started", extra: ["turn_id": "first"]))
        reducer.consume(event("task_complete", at: time.addingTimeInterval(10), extra: ["turn_id": "first"]))
        XCTAssertEqual(reducer.activity.phase, .completed)
        reducer.consume(event("task_started", at: time.addingTimeInterval(20), extra: ["turn_id": "second"]))
        reducer.consume(event("task_complete", at: time.addingTimeInterval(21), extra: ["turn_id": "first"]))
        XCTAssertEqual(reducer.activity.phase, .running)
        XCTAssertEqual(reducer.activity.startedAt, time.addingTimeInterval(20))
        reducer.consume(event("turn_aborted", at: time.addingTimeInterval(22)))
        XCTAssertEqual(reducer.activity.phase, .stopped)
    }
    func testEveryTerminalEventIgnoresAnOlderTurnAndAcceptsTheCurrentTurn() {
        let terminals: [(String, TaskPhase)] = [("task_complete", .completed), ("turn_complete", .completed),
            ("turn_aborted", .stopped), ("task_cancelled", .stopped), ("turn_cancelled", .stopped),
            ("task_failed", .failed), ("turn_failed", .failed)]
        for (type, expected) in terminals {
            var reducer = RolloutReducer()
            reducer.consume(event("task_started", extra: ["turn_id": "first"]))
            reducer.consume(event("task_complete", at: time.addingTimeInterval(1), extra: ["turn_id": "first"]))
            reducer.consume(event("task_started", at: time.addingTimeInterval(2), extra: ["turn_id": "second"]))
            reducer.consume(event(type, at: time.addingTimeInterval(3), extra: ["turn_id": "first"]))
            XCTAssertEqual(reducer.activity.phase, .running, type)
            XCTAssertEqual(reducer.activity.turnID, "second", type)
            XCTAssertEqual(reducer.activity.lastEventAt, time.addingTimeInterval(2), type)
            reducer.consume(event(type, at: time.addingTimeInterval(4), extra: ["turn_id": "second"]))
            XCTAssertEqual(reducer.activity.phase, expected, type)
        }
    }
    func testFailedTurnSurvivesTrailingMessagesToolsAndCompletionWhileQuotaStillUpdates() {
        let trailing: [(String, String, [String: Any])] = [
            ("event_msg", "agent_message", [:]), ("event_msg", "agent_reasoning", [:]),
            ("event_msg", "item_completed", ["item": ["type": "commandExecution"]]),
            ("event_msg", "request_user_input", [:]), ("event_msg", "task_complete", ["turn_id": "failed"]),
            ("response_item", "function_call", ["name": "exec_command"]),
            ("response_item", "custom_tool_call", ["name": "request_user_input", "call_id": "question"]),
            ("response_item", "function_call_output", ["call_id": "question"])
        ]
        for failure in ["task_failed", "turn_failed"] {
            var reducer = RolloutReducer()
            reducer.consume(event("task_started", extra: ["turn_id": "failed"]))
            reducer.consume(event(failure, at: time.addingTimeInterval(1), extra: ["turn_id": "failed"]))
            for (index, item) in trailing.enumerated() {
                reducer.consume(event(item.1, at: time.addingTimeInterval(Double(index + 2)), extra: item.2, kind: item.0))
                XCTAssertEqual(reducer.activity.phase, .failed, "\(failure) followed by \(item.1)")
                XCTAssertEqual(reducer.activity.turnID, "failed")
            }
            reducer.consume(event("token_count", at: time.addingTimeInterval(20), extra: ["rate_limits": ["limit_id": "codex", "primary": ["used_percent": 19.0, "window_minutes": 300]]]))
            XCTAssertEqual(reducer.activity.phase, .failed)
            XCTAssertEqual(reducer.quota?.fiveHour?.remainingPercent, 81)
        }
    }
    func testFailedTurnResumesOnlyOnExplicitStartOrUserContinuation() {
        let continuations: [(String, [String: Any], String?)] = [
            ("task_started", ["turn_id": "resumed"], "resumed"), ("turn_started", ["turn_id": "resumed"], "resumed"),
            ("user_message", [:], nil), ("user_input", [:], nil), ("approval_resolved", [:], nil),
            ("item_completed", ["item": ["type": "userMessage"]], nil)
        ]
        for (type, extra, expectedTurn) in continuations {
            var reducer = RolloutReducer()
            reducer.consume(event("task_started", extra: ["turn_id": "failed"]))
            reducer.consume(event("task_failed", at: time.addingTimeInterval(1)))
            reducer.consume(event(type, at: time.addingTimeInterval(2), extra: extra))
            XCTAssertEqual(reducer.activity.phase, .running, type)
            XCTAssertEqual(reducer.activity.startedAt, time.addingTimeInterval(2), type)
            XCTAssertEqual(reducer.activity.turnID, expectedTurn, type)
        }
    }
    func testWaitingOnlyResolvesOnMatchingAnswer() {
        var reducer = RolloutReducer()
        reducer.consume(event("function_call", extra: ["name": "request_user_input", "call_id": "question"], kind: "response_item"))
        reducer.consume(event("function_call_output", extra: ["call_id": "unrelated"], kind: "response_item"))
        XCTAssertEqual(reducer.activity.phase, .waiting)
        reducer.consume(event("function_call_output", extra: ["call_id": "question"], kind: "response_item"))
        XCTAssertEqual(reducer.activity.phase, .running)
    }
    func testAsyncQuestionDoesNotResolveOnToolReturnOrTurnComplete() {
        var reducer = RolloutReducer()
        reducer.consume(event("function_call", extra: ["name": "request_user_input_async", "call_id": "question"], kind: "response_item"))
        reducer.consume(event("function_call_output", extra: ["call_id": "question"], kind: "response_item"))
        reducer.consume(event("task_complete"))
        XCTAssertEqual(reducer.activity.phase, .waiting)
        reducer.consume(event("user_message"))
        XCTAssertEqual(reducer.activity.phase, .running)
    }
    func testStaleRunningIsUnknownButFinishedAndWaitingRemain() {
        let old = time.addingTimeInterval(-1000)
        XCTAssertEqual(TaskActivity(phase: .running, lastEventAt: old).effective(at: time).phase, .unknown)
        XCTAssertEqual(TaskActivity(phase: .completed, lastEventAt: old).effective(at: time).phase, .completed)
        XCTAssertEqual(TaskActivity(phase: .waiting, lastEventAt: old).effective(at: time).phase, .waiting)
    }
    func testQuotaIdentifiesWindowByDurationNotPosition() {
        var reducer = RolloutReducer()
        reducer.consume(event("token_count", extra: ["rate_limits": ["limit_id": "codex", "primary": ["used_percent": 85.0, "window_minutes": 10080], "secondary": ["used_percent": 19.0, "window_minutes": 300]]]))
        XCTAssertEqual(reducer.quota?.weekly?.remainingPercent, 15)
        XCTAssertEqual(reducer.quota?.fiveHour?.remainingPercent, 81)
    }
    func testMalformedAndOutOfOrderEventsDoNotCorruptState() {
        var reducer = RolloutReducer()
        reducer.consume(event("task_complete"))
        reducer.consume(Data("garbage".utf8))
        reducer.consume(event("task_started", at: time.addingTimeInterval(-1)))
        XCTAssertEqual(reducer.activity.phase, .completed)
    }
    func testIncrementalPartialLineTruncationAndNoReread() throws {
        let file = try temporary().appendingPathComponent("rollout.jsonl")
        let first = event("task_started") + Data([10])
        try first.write(to: file)
        var tail = IncrementalRollout()
        XCTAssertEqual(try tail.refresh(url: file), first.count)
        XCTAssertEqual(try tail.refresh(url: file), 0)
        let complete = event("task_complete")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: complete.prefix(15)); try handle.close()
        _ = try tail.refresh(url: file)
        XCTAssertEqual(tail.reducer.activity.phase, .running)
        let end = try FileHandle(forWritingTo: file)
        try end.seekToEnd(); try end.write(contentsOf: complete.dropFirst(15) + Data([10])); try end.close()
        _ = try tail.refresh(url: file)
        XCTAssertEqual(tail.reducer.activity.phase, .completed)
        try (event("turn_aborted") + Data([10])).write(to: file, options: .atomic)
        _ = try tail.refresh(url: file)
        XCTAssertEqual(tail.reducer.activity.phase, .stopped)
    }
    func testLargeHistoryIsBoundedAndRecoversAfterOversizeLine() throws {
        let file = try temporary().appendingPathComponent("rollout.jsonl")
        try (Data(repeating: 120, count: 5000) + Data([10]) + event("task_complete") + Data([10])).write(to: file)
        var tail = IncrementalRollout(maximumRead: 1000)
        XCTAssertLessThanOrEqual(try tail.refresh(url: file), 1024)
        XCTAssertEqual(tail.reducer.activity.phase, .completed)
    }
    func testFirstScanAndAutoMonitorDoNotFloodHistory() {
        var preferences = MonitorPreferences()
        let old = task("history", phase: .completed), active = task("active", phase: .running)
        MonitoringPolicy.reconcile(&preferences, tasks: [old, active], now: time)
        XCTAssertEqual(preferences.selectedIDs, ["active"])
        let fresh = task("fresh", phase: .completed, createdAt: time.addingTimeInterval(1))
        MonitoringPolicy.reconcile(&preferences, tasks: [old, active, fresh], now: time.addingTimeInterval(2))
        XCTAssertEqual(preferences.selectedIDs, ["active", "fresh"])
    }
    func testSameSecondAutoEnableAddsNewIDsButNotKnownTasksAndPreservesExclusions() {
        var p = MonitorPreferences(); p.initialized = true; p.autoMonitor = false
        let old = task("known", phase: .completed, createdAt: time)
        MonitoringPolicy.setAutoMonitor(true, preferences: &p, tasks: [old], now: time.addingTimeInterval(0.25))
        var fresh = task("fresh", createdAt: time)
        MonitoringPolicy.reconcile(&p, tasks: [old, fresh], now: time.addingTimeInterval(0.4))
        XCTAssertTrue(p.selectedIDs.isEmpty, "An idle task has not started yet")
        fresh.activity = TaskActivity(phase: .running, startedAt: time.addingTimeInterval(0.5))
        MonitoringPolicy.reconcile(&p, tasks: [old, fresh], now: time.addingTimeInterval(1))
        XCTAssertEqual(p.selectedIDs, ["fresh"])
        MonitoringPolicy.applySelection([], original: ["fresh"], preferences: &p)
        MonitoringPolicy.reconcile(&p, tasks: [old, fresh], now: time.addingTimeInterval(2))
        XCTAssertTrue(p.selectedIDs.isEmpty)
        XCTAssertTrue(p.excludedIDs.contains("fresh"))

        MonitoringPolicy.setAutoMonitor(false, preferences: &p, tasks: [old, fresh], now: time.addingTimeInterval(2))
        let whileOff = task("while-off", phase: .running, createdAt: time.addingTimeInterval(2))
        MonitoringPolicy.reconcile(&p, tasks: [old, fresh, whileOff], now: time.addingTimeInterval(2.1))
        XCTAssertTrue(p.selectedIDs.isEmpty)
        MonitoringPolicy.setAutoMonitor(true, preferences: &p, tasks: [old, fresh, whileOff], now: time.addingTimeInterval(2.25))
        let afterEnable = task("after-enable", phase: .waiting, createdAt: time.addingTimeInterval(2))
        MonitoringPolicy.reconcile(&p, tasks: [old, fresh, whileOff, afterEnable], now: time.addingTimeInterval(3))
        XCTAssertEqual(p.selectedIDs, ["after-enable"])
    }
    func testFirstScanBoundaryAndRestartKeepHistoricalTasksOut() throws {
        var p = MonitorPreferences()
        let old = task("same-second-history", phase: .completed, createdAt: time)
        let active = task("active", phase: .running)
        MonitoringPolicy.reconcile(&p, tasks: [old, active], now: time.addingTimeInterval(0.25))
        XCTAssertEqual(p.selectedIDs, ["active"])
        p = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(p))
        let fresh = task("fresh", phase: .completed, createdAt: time)
        MonitoringPolicy.reconcile(&p, tasks: [old, active, fresh], now: time.addingTimeInterval(2))
        XCTAssertEqual(p.selectedIDs, ["active", "fresh"])
        XCTAssertEqual(p.autoBaselineIDs, ["same-second-history", "active"])
    }
    func testLegacyPreferencesEstablishBoundaryBaselineWithoutLosingLaterCatchUp() throws {
        var p = MonitorPreferences(); p.initialized = true; p.autoEnabledAt = time.addingTimeInterval(0.25)
        p.selectedIDs = ["kept"]; p.excludedIDs = ["excluded"]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        legacy.removeValue(forKey: "autoBaselineIDs")
        p = try JSONDecoder().decode(MonitorPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(p.autoBaselineIDs)
        let boundary = task("ambiguous-history", phase: .completed, createdAt: time)
        let later = task("later", phase: .completed, createdAt: time.addingTimeInterval(1))
        let excluded = task("excluded", phase: .running, createdAt: time.addingTimeInterval(1))
        MonitoringPolicy.reconcile(&p, tasks: [boundary, later, excluded], now: time.addingTimeInterval(2))
        XCTAssertEqual(p.selectedIDs, ["kept", "later"])
        XCTAssertEqual(p.autoBaselineIDs, ["ambiguous-history"])
        XCTAssertEqual(p.excludedIDs, ["excluded"])
    }
    func testManualExclusionWinsAndSelectionPreservesConcurrentAddition() {
        var p = MonitorPreferences(); p.initialized = true; p.autoEnabledAt = time
        p.selectedIDs = ["a", "new-arrival"]
        MonitoringPolicy.applySelection([], original: ["a"], preferences: &p)
        XCTAssertEqual(p.selectedIDs, ["new-arrival"])
        MonitoringPolicy.reconcile(&p, tasks: [task("a", phase: .running, createdAt: time)], now: time)
        XCTAssertFalse(p.selectedIDs.contains("a"))
        MonitoringPolicy.applySelection(["a"], original: [], preferences: &p)
        XCTAssertFalse(p.excludedIDs.contains("a"))
    }
    func testAutoOffAndSelectAllOnlyAffectCurrentResults() {
        var p = MonitorPreferences(); p.initialized = true; p.autoMonitor = false
        MonitoringPolicy.reconcile(&p, tasks: [task("new", phase: .running, createdAt: time)], now: time)
        XCTAssertTrue(p.selectedIDs.isEmpty)
        var selected: Set<String> = ["outside"]
        MonitoringPolicy.selectVisible(["a", "b"], selected: &selected)
        XCTAssertEqual(selected, ["outside", "a", "b"])
        MonitoringPolicy.selectVisible(["a", "b"], selected: &selected)
        XCTAssertEqual(selected, ["outside"])
    }
    func testChildIsFoldedUnderRootAndElevatesAttention() {
        let tasks = [task("parent", phase: .completed), task("child", phase: .waiting, parent: "parent")]
        XCTAssertEqual(MonitoringPolicy.roots(in: tasks).map(\.id), ["parent"])
        XCTAssertEqual(MonitoringPolicy.activity(for: tasks[0], tasks: tasks).phase, .waiting)
        var p = MonitorPreferences()
        MonitoringPolicy.reconcile(&p, tasks: tasks, now: time)
        XCTAssertEqual(p.selectedIDs, ["parent"])
    }
    func testGraphHandlesGrandchildrenOrphansAndCycles() {
        let items = [task("a"), task("b", parent: "a"), task("c", parent: "b"), task("orphan", parent: "missing"), task("x", parent: "y"), task("y", parent: "x")]
        let graph = TaskGraph(tasks: items)
        XCTAssertEqual(Set(graph.roots.map(\.id)), ["a", "orphan", "x"])
        XCTAssertEqual(Set(graph.children["a"]!.map(\.id)), ["b", "c"])
        XCTAssertEqual(graph.rootIDs["y"], "x")
    }
    func testThemeAdditionKeepsOlderPreferencesReadable() throws {
        var preferences = MonitorPreferences()
        preferences.selectedIDs = ["kept-task"]
        preferences.theme = .light
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(MonitorPreferences.self, from: data).theme, .light)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "theme")
        let restored = try JSONDecoder().decode(MonitorPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.selectedIDs, ["kept-task"])
        XCTAssertNil(restored.theme)
    }

    func testPreferencesRoundTripAndCorruptionIsNotSilentlyOverwritten() throws {
        let file = PreferencesFile(url: try temporary().appendingPathComponent("preferences.json"))
        var p = MonitorPreferences(); p.selectedIDs = ["a"]; p.preferredDisplay = "display-one"; p.floating = true
        try file.save(p); XCTAssertEqual(try file.load(), p)
        let corrupt = Data("broken".utf8); try corrupt.write(to: file.url)
        XCTAssertThrowsError(try file.load()); XCTAssertEqual(try Data(contentsOf: file.url), corrupt)
    }
    func testDisplayModesAndScalePreserveLegacyPreferencesAndTaskSelection() throws {
        var p = MonitorPreferences(); p.floating = true; p.selectedIDs = ["kept"]
        let legacy = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(legacy.resolvedPlacement, .floating)
        XCTAssertEqual(legacy.resolvedScale, 1)
        for mode in PanelPlacement.allCases {
            p.placement = mode; p.uiScale = 0.8
            let restored = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(p))
            XCTAssertEqual(restored.resolvedPlacement, mode)
            XCTAssertEqual(restored.resolvedScale, 0.8)
            XCTAssertEqual(restored.selectedIDs, ["kept"])
        }
        p.uiScale = -5; XCTAssertEqual(p.resolvedScale, 0.8)
        p.uiScale = 8; XCTAssertEqual(p.resolvedScale, 1)
    }
    func testRealSQLiteReadOnlyAdapterFiltersArchivesAndBlocksOutsidePaths() async throws {
        let root = try temporary(), db = root.appendingPathComponent("state_5.sqlite"), log = root.appendingPathComponent("rollout.jsonl")
        try (event("task_complete") + Data([10])).write(to: log)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &connection), SQLITE_OK)
        let sql = """
        CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER);
        INSERT INTO threads VALUES('live','Demo','/example/Demo','\(log.path)',1,2,0);
        INSERT INTO threads VALUES('archived','Old','/example/Old','\(log.path)',1,2,1);
        INSERT INTO threads VALUES('outside','Outside','/example/Other','/tmp/outside.jsonl',1,2,0);
        """
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(connection)
        let original = try Data(contentsOf: db)
        let source = LocalCodexSource(root: root), snapshot = try await source.snapshot(now: time)
        XCTAssertEqual(snapshot.tasks.count, 2)
        XCTAssertEqual(snapshot.tasks.first(where: { $0.id == "live" })?.activity.phase, .completed)
        XCTAssertEqual(snapshot.tasks.first(where: { $0.id == "outside" })?.activity.phase, .unknown)
        XCTAssertNotNil(snapshot.warning)
        let next = try await source.snapshot(now: time)
        XCTAssertEqual(next.bytesRead, 0)
        XCTAssertEqual(try Data(contentsOf: db), original)
    }
    func testMissingAndUnsupportedDatabaseHaveActionableErrors() async throws {
        let root = try temporary()
        do { _ = try await LocalCodexSource(root: root).snapshot(); XCTFail("missing database should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未找到")) }
        var db: OpaquePointer?
        sqlite3_open(root.appendingPathComponent("state_99.sqlite").path, &db)
        sqlite3_exec(db, "CREATE TABLE threads(other TEXT)", nil, nil, nil); sqlite3_close(db)
        do { _ = try await LocalCodexSource(root: root).snapshot(); XCTFail("unsupported schema should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("格式不受支持")) }
    }
}
