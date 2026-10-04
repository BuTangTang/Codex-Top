import XCTest
@testable import CodexTopCore

final class MonitoringGraphReuseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 同一份任务和图重复使用时，时间推进仍须触发过期移除。
    func testUnchangedGraphStillRetiresAtLaterTimeBoundary() {
        let last = now.addingTimeInterval(-7 * 86_400 + 1)
        let tasks = [task("root", phase: .completed, last: last)]
        let graph = TaskGraph(tasks: tasks)
        var preferences = MonitorPreferences()
        preferences.initialized = true
        preferences.autoMonitor = false
        preferences.autoBaselineIDs = ["root"]
        preferences.selectedIDs = ["root"]
        preferences.finishedRetentionDays = 7

        MonitoringPolicy.reconcile(&preferences, tasks: tasks, graph: graph, now: now)
        XCTAssertEqual(preferences.selectedIDs, ["root"])
        MonitoringPolicy.reconcile(&preferences, tasks: tasks, graph: graph, now: now.addingTimeInterval(1))
        XCTAssertTrue(preferences.selectedIDs.isEmpty)
        XCTAssertEqual(preferences.automaticallyRemovedIDs, ["root"])
    }

    /// 原公开入口与同快照复用入口对初始化、子任务与旧版偏好保持相同策略。
    func testOriginalEntryAndPrebuiltGraphPreserveDiscoveryAndLegacyPreferences() {
        let tasks = [task("root", phase: .completed, last: now),
                     task("child", phase: .waiting, last: now, parent: "root"),
                     task("excluded", phase: .running, last: now)]
        let graph = TaskGraph(tasks: tasks)
        var initial = MonitorPreferences()
        initial.excludedIDs = ["excluded"]
        var legacy = initial
        legacy.initialized = true
        legacy.autoEnabledAt = now.addingTimeInterval(-10)
        legacy.autoBaselineIDs = nil
        for starting in [initial, legacy] {
            var original = starting, reused = starting
            MonitoringPolicy.reconcile(&original, tasks: tasks, now: now)
            MonitoringPolicy.reconcile(&reused, tasks: tasks, graph: graph, now: now)
            XCTAssertEqual(reused, original)
            XCTAssertEqual(reused.selectedIDs, ["root"])
            XCTAssertEqual(reused.excludedIDs, ["excluded"])
            XCTAssertNotNil(reused.autoBaselineIDs)
        }
    }

    /// 仅生成合成任务，时间和父子关系由用例显式指定。
    private func task(_ id: String, phase: TaskPhase, last: Date, parent: String? = nil) -> CodexTask {
        var task = CodexTask(id: id, title: id, project: "Synthetic", createdAt: now,
                             updatedAt: last, parentID: parent, rolloutURL: URL(fileURLWithPath: "/synthetic/rollout"))
        task.activity = TaskActivity(phase: phase, lastEventAt: last)
        return task
    }
}
