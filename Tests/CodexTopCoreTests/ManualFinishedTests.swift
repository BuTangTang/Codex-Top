import XCTest
@testable import CodexTopCore

final class ManualFinishedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func task(_ id: String = "root", phase: TaskPhase = .completed, parent: String? = nil) -> CodexTask {
        var task = CodexTask(id: id, title: "Synthetic", project: "Synthetic", createdAt: now.addingTimeInterval(-100),
                             updatedAt: now, parentID: parent, rolloutURL: URL(fileURLWithPath: "/synthetic/log"))
        task.activity = TaskActivity(phase: phase, lastEventAt: now, startedAt: now.addingTimeInterval(-60))
        task.activity.turnID = "first"
        task.activity.finishedAt = phase.isFinished ? now : nil
        return task
    }
    private func preferences() -> MonitorPreferences {
        var p = MonitorPreferences(); p.initialized = true; p.autoMonitor = false; p.selectedIDs = ["root"]
        return p
    }
    private func file(_ tasks: [CodexTask], preferences: inout MonitorPreferences) {
        let graph = TaskGraph(tasks: tasks)
        MonitoringPolicy.finish(tasks[0], preferences: &preferences, graph: graph, now: now)
    }
    func testCompletedTaskStaysAboveAndNeverAgesOutWithoutManualFiling() throws {
        let root = task()
        var p = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(preferences()))
        XCTAssertNil(p.manuallyFinishedTasks, "Legacy preferences must not silently file any task")
        MonitoringPolicy.reconcile(&p, tasks: [root], now: now.addingTimeInterval(40 * 86_400))
        XCTAssertEqual(p.selectedIDs, ["root"])
        XCTAssertFalse(MonitoringPolicy.isManuallyFinished(root, preferences: p, graph: TaskGraph(tasks: [root])))
        file([root], preferences: &p)
        XCTAssertTrue(MonitoringPolicy.isManuallyFinished(root, preferences: p, graph: TaskGraph(tasks: [root])))
        XCTAssertEqual(p.selectedIDs, ["root"])
        XCTAssertTrue(p.excludedIDs.isEmpty)
    }
    func testFilingSurvivesRestartAndTrailingUsageAndMetadataUpdates() throws {
        var root = task(), p = preferences()
        file([root], preferences: &p)
        p = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(p))
        root.updatedAt = now.addingTimeInterval(20)
        root.activity.lastEventAt = now.addingTimeInterval(20)
        root.activity.finishedAt = now.addingTimeInterval(20) // repeated terminal event for the same round
        MonitoringPolicy.reconcile(&p, tasks: [root], now: now.addingTimeInterval(20))
        XCTAssertTrue(MonitoringPolicy.isManuallyFinished(root, preferences: p, graph: TaskGraph(tasks: [root])))
    }
    func testRunningWaitingAndFailedResumeEvenWithoutTimestamps() {
        for phase in [TaskPhase.running, .waiting, .failed] {
            var root = task(), p = preferences()
            file([root], preferences: &p)
            root.activity = TaskActivity(phase: phase)
            MonitoringPolicy.reconcile(&p, tasks: [root], now: now)
            XCTAssertNil(p.manuallyFinishedTasks?[root.id], "\(phase)")
            XCTAssertEqual(p.selectedIDs, [root.id])
        }
    }
    func testWholeNewRoundBetweenScansReturnsByIDStartOrExplicitEnd() {
        for evidence in 0..<3 {
            var root = task(), p = preferences()
            if evidence == 2 { root.activity.turnID = nil; root.activity.startedAt = nil }
            file([root], preferences: &p)
            if evidence == 0 { root.activity.turnID = "second" }
            if evidence == 1 { root.activity.startedAt = now.addingTimeInterval(1) }
            if evidence == 2 { root.activity.finishedAt = now.addingTimeInterval(2) }
            MonitoringPolicy.reconcile(&p, tasks: [root], now: now.addingTimeInterval(3))
            XCTAssertNil(p.manuallyFinishedTasks?[root.id])
            XCTAssertEqual(p.selectedIDs, [root.id])
        }
    }
    func testChildResumeAndNewCompletedChildReopenParent() {
        let root = task()
        for phase in [TaskPhase.running, .waiting, .completed] {
            var child = task("child", parent: "root"), p = preferences()
            file([root, child], preferences: &p)
            child.activity.phase = phase; child.activity.turnID = "second"
            MonitoringPolicy.reconcile(&p, tasks: [root, child], now: now)
            XCTAssertNil(p.manuallyFinishedTasks?[root.id])
        }
        var p = preferences()
        file([root], preferences: &p)
        var newChild = task("new-child", parent: "root")
        newChild.activity.finishedAt = now.addingTimeInterval(1)
        MonitoringPolicy.reconcile(&p, tasks: [root, newChild], now: now.addingTimeInterval(2))
        XCTAssertNil(p.manuallyFinishedTasks?[root.id])
    }
    func testUnknownIsVisibleWithoutLosingFilingAndCannotBeFiled() {
        var root = task(), p = preferences()
        file([root], preferences: &p)
        let saved = p.manuallyFinishedTasks
        root.activity = TaskActivity(phase: .unknown)
        MonitoringPolicy.reconcile(&p, tasks: [root], now: now)
        XCTAssertFalse(MonitoringPolicy.isManuallyFinished(root, preferences: p, graph: TaskGraph(tasks: [root])))
        XCTAssertEqual(p.manuallyFinishedTasks, saved)
        p = preferences(); file([root], preferences: &p)
        XCTAssertNil(p.manuallyFinishedTasks)
        let completed = task(), missing = task("child", phase: .unknown, parent: "root")
        XCTAssertFalse(MonitoringPolicy.canFinish(completed, graph: TaskGraph(tasks: [completed, missing])))
    }
    func testExplicitRemovalAndReadditionClearFilingWithoutChangingExclusionRules() {
        let root = task(); var p = preferences()
        file([root], preferences: &p)
        MonitoringPolicy.applySelection([], original: [root.id], preferences: &p)
        XCTAssertNil(p.manuallyFinishedTasks?[root.id])
        MonitoringPolicy.reconcile(&p, tasks: [task(phase: .running)], now: now)
        XCTAssertTrue(p.selectedIDs.isEmpty)
        MonitoringPolicy.applySelection([root.id], original: [], preferences: &p)
        MonitoringPolicy.reconcile(&p, tasks: [root], now: now)
        XCTAssertEqual(p.selectedIDs, [root.id])
        XCTAssertFalse(MonitoringPolicy.isManuallyFinished(root, preferences: p, graph: TaskGraph(tasks: [root])))
    }
    func testAutoRetiredFiledTaskReturnsAfterAnUnobservedNewRound() {
        var root = task(), p = preferences()
        file([root], preferences: &p)
        MonitoringPolicy.reconcile(&p, tasks: [root], now: now.addingTimeInterval(8 * 86_400))
        XCTAssertTrue(p.selectedIDs.isEmpty)
        root.activity.turnID = "second"
        MonitoringPolicy.reconcile(&p, tasks: [root], now: now.addingTimeInterval(9 * 86_400))
        XCTAssertEqual(p.selectedIDs, [root.id], "An explicit new round is sufficient even with stale DB dates")
        XCTAssertNil(p.manuallyFinishedTasks?[root.id])
    }
    func testReducerTerminalTimestampDoesNotFollowTrailingUsageAndClearsOnResume() throws {
        var reducer = RolloutReducer()
        func event(_ type: String, at: Date, turn: String? = nil) throws -> Data {
            var payload = ["type": type]; payload["turn_id"] = turn
            return try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: at), "payload": payload])
        }
        reducer.consume(try event("task_complete", at: now, turn: "first"))
        XCTAssertEqual(reducer.activity.finishedAt, now)
        XCTAssertEqual(reducer.activity.turnID, "first", "Cold tail completion retains the explicit round ID")
        reducer.consume(try event("token_count", at: now.addingTimeInterval(1)))
        XCTAssertEqual(reducer.activity.finishedAt, now)
        reducer.consume(try event("user_message", at: now.addingTimeInterval(2)))
        XCTAssertNil(reducer.activity.finishedAt)
        XCTAssertEqual(reducer.activity.phase, .running)
    }
}
