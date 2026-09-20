import XCTest
@testable import CodexTopCore

final class FinishedRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func task(_ id: String, phase: TaskPhase, daysAgo: Double, parent: String? = nil) -> CodexTask {
        let last = now.addingTimeInterval(-daysAgo * 86_400)
        var task = CodexTask(id: id, title: id, project: "Synthetic", createdAt: now.addingTimeInterval(-100 * 86_400),
                             updatedAt: last, parentID: parent, rolloutURL: URL(fileURLWithPath: "/synthetic/rollout"))
        task.activity = TaskActivity(phase: phase, lastEventAt: last)
        return task
    }
    private func preferences(_ ids: Set<String>) -> MonitorPreferences {
        var result = MonitorPreferences()
        result.initialized = true; result.autoMonitor = false
        result.selectedIDs = ids; result.finishedRetentionDays = 7
        return result
    }
    func testOnlyOldTerminalConversationsExpireAtBoundary() {
        let tasks = [task("old", phase: .completed, daysAgo: 8), task("boundary", phase: .stopped, daysAgo: 7),
                     task("recent", phase: .completed, daysAgo: 6.999), task("running", phase: .running, daysAgo: 20),
                     task("waiting", phase: .waiting, daysAgo: 20), task("unknown", phase: .unknown, daysAgo: 20),
                     task("failed", phase: .failed, daysAgo: 20), task("idle", phase: .idle, daysAgo: 20)]
        var p = preferences(Set(tasks.map(\.id)))
        MonitoringPolicy.reconcile(&p, tasks: tasks, now: now)
        XCTAssertEqual(p.automaticallyRemovedIDs, ["old", "boundary"])
        XCTAssertEqual(p.selectedIDs, ["recent", "running", "waiting", "unknown", "failed", "idle"])
        XCTAssertTrue(p.excludedIDs.isEmpty)
    }
    func testLatestChildActivityAndUncertainChildrenPreventRetirement() {
        let root = task("root", phase: .completed, daysAgo: 30)
        for child in [task("child", phase: .completed, daysAgo: 1, parent: "root"),
                      task("child", phase: .running, daysAgo: 10, parent: "root"),
                      task("child", phase: .waiting, daysAgo: 10, parent: "root"),
                      task("child", phase: .unknown, daysAgo: 10, parent: "root")] {
            var p = preferences(["root"])
            MonitoringPolicy.reconcile(&p, tasks: [root, child], now: now)
            XCTAssertEqual(p.selectedIDs, ["root"])
        }
        var recentEvent = root
        recentEvent.activity.lastEventAt = now
        var p = preferences(["root"])
        MonitoringPolicy.reconcile(&p, tasks: [recentEvent], now: now)
        XCTAssertEqual(p.selectedIDs, ["root"], "An old creation or DB timestamp must not override recent activity")
    }
    func testRetirementPersistsAndResumedTasksReturnButManualExclusionsDoNot() throws {
        let old = task("old", phase: .completed, daysAgo: 8)
        var p = preferences(["old"])
        MonitoringPolicy.reconcile(&p, tasks: [old], now: now)
        p = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(p))
        MonitoringPolicy.reconcile(&p, tasks: [old], now: now)
        XCTAssertTrue(p.selectedIDs.isEmpty)
        var resumed = task("old", phase: .running, daysAgo: 0)
        resumed.updatedAt = Date(timeIntervalSince1970: 0)
        resumed.activity.lastEventAt = nil
        MonitoringPolicy.reconcile(&p, tasks: [resumed], now: now)
        XCTAssertEqual(p.selectedIDs, ["old"])
        MonitoringPolicy.applySelection([], original: ["old"], preferences: &p)
        MonitoringPolicy.reconcile(&p, tasks: [resumed], now: now)
        XCTAssertTrue(p.selectedIDs.isEmpty)
        XCTAssertEqual(p.excludedIDs, ["old"])
    }
    func testManualReadditionIsKeptAndDisablingRestoresOnlyAutomaticRemovals() {
        let tasks = [task("restore", phase: .completed, daysAgo: 8), task("retired", phase: .stopped, daysAgo: 8),
                     task("manual", phase: .completed, daysAgo: 8)]
        var p = preferences(Set(tasks.map(\.id)))
        MonitoringPolicy.applySelection(["restore", "retired"], original: p.selectedIDs, preferences: &p)
        MonitoringPolicy.reconcile(&p, tasks: tasks, now: now)
        MonitoringPolicy.applySelection(["restore"], original: [], preferences: &p)
        MonitoringPolicy.reconcile(&p, tasks: tasks, now: now.addingTimeInterval(100 * 86_400))
        XCTAssertEqual(p.selectedIDs, ["restore"])
        p.finishedRetentionDays = 0
        MonitoringPolicy.reconcile(&p, tasks: tasks, now: now)
        XCTAssertEqual(p.selectedIDs, ["restore", "retired"])
        XCTAssertEqual(p.excludedIDs, ["manual"])
    }
    func testAutoDiscoveryDoesNotReaddExpiredTasksEveryRefresh() {
        var old = task("old", phase: .completed, daysAgo: 8)
        old.createdAt = now.addingTimeInterval(-9 * 86_400)
        var p = preferences(["old"])
        p.autoMonitor = true; p.autoEnabledAt = now.addingTimeInterval(-10 * 86_400); p.autoBaselineIDs = []
        MonitoringPolicy.reconcile(&p, tasks: [old], now: now)
        let retired = p
        MonitoringPolicy.reconcile(&p, tasks: [old], now: now)
        XCTAssertEqual(p, retired)
        XCTAssertTrue(p.selectedIDs.isEmpty)
    }
    func testLegacyPreferenceDefaultsAndInvalidValue() throws {
        let data = try JSONEncoder().encode(MonitorPreferences())
        let legacy = try JSONDecoder().decode(MonitorPreferences.self, from: data)
        XCTAssertEqual(legacy.resolvedFinishedRetentionDays, 7)
        var invalid = legacy; invalid.finishedRetentionDays = -10
        XCTAssertEqual(invalid.resolvedFinishedRetentionDays, 7)
    }
    func testMissingOrInvalidTimesAreNotTreatedAsOldActivity() {
        for timestamp in [0.0, Double.nan] {
            var missing = task("missing", phase: .completed, daysAgo: 20)
            missing.updatedAt = Date(timeIntervalSince1970: timestamp)
            missing.activity.lastEventAt = nil
            var p = preferences(["missing"])
            MonitoringPolicy.reconcile(&p, tasks: [missing], now: now)
            XCTAssertEqual(p.selectedIDs, ["missing"])
            missing.parentID = "root"
            p = preferences(["root"])
            MonitoringPolicy.reconcile(&p, tasks: [task("root", phase: .completed, daysAgo: 20), missing], now: now)
            XCTAssertEqual(p.selectedIDs, ["root"])
        }
    }
}
