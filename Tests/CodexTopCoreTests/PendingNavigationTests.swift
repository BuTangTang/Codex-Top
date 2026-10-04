import Foundation
import XCTest
@testable import CodexTopCore

final class PendingNavigationTests: XCTestCase {
    private func task(_ id: String, phase: TaskPhase, parent: String? = nil) -> CodexTask {
        var task = CodexTask(id: id, title: "Synthetic task", project: "Fixture",
                             createdAt: .distantPast, updatedAt: .distantPast,
                             parentID: parent, rolloutURL: URL(fileURLWithPath: "/tmp/synthetic-rollout.jsonl"))
        task.activity = TaskActivity(phase: phase)
        return task
    }

    func testPendingDescendantOpensItsOwnTaskInsteadOfCompletedRoot() {
        let root = task("00000000-0000-0000-0000-000000000001", phase: .completed)
        let child = task("00000000-0000-0000-0000-000000000002", phase: .running, parent: root.id)
        let pending = task("00000000-0000-0000-0000-000000000003", phase: .waiting, parent: child.id)
        let graph = TaskGraph(tasks: [root, child, pending])
        XCTAssertEqual(graph.activity(for: root).phase, .waiting)
        XCTAssertEqual(graph.navigationTarget(for: root).id, pending.id)
        XCTAssertEqual(graph.navigationTarget(for: root).deepLink?.absoluteString, "codex://threads/\(pending.id)")
    }

    func testEqualPriorityUsesSameSourceForStatusTimingAndNavigation() {
        let root = task("root", phase: .running)
        var first = task("first", phase: .waiting, parent: root.id)
        var second = task("second", phase: .waiting, parent: root.id)
        first.activity.waitingStartedAt = Date(timeIntervalSince1970: 1_800_000_010)
        second.activity.waitingStartedAt = Date(timeIntervalSince1970: 1_800_000_020)
        for tasks in [[root, first, second], [root, second, first]] {
            let graph = TaskGraph(tasks: tasks)
            XCTAssertEqual(graph.activity(for: root).waitingStartedAt, graph.navigationTarget(for: root).activity.waitingStartedAt)
            XCTAssertEqual(graph.navigationTarget(for: root).id, tasks[1].id)
        }
    }

    func testRootQuestionKeepsRootDestinationWhenChildAlsoWaits() {
        let root = task("root", phase: .waiting)
        let child = task("child", phase: .waiting, parent: root.id)
        let graph = TaskGraph(tasks: [root, child])
        XCTAssertEqual(graph.navigationTarget(for: root).id, root.id)
        XCTAssertEqual(graph.activitySource(for: root).id, root.id)
    }

    func testResolvedChildAndNonPendingStatesReturnToRootDestination() {
        let root = task("root", phase: .completed)
        var child = task("child", phase: .waiting, parent: root.id)
        XCTAssertEqual(TaskGraph(tasks: [root, child]).navigationTarget(for: root).id, child.id)
        for phase in TaskPhase.allCases where phase != .waiting {
            child.activity = TaskActivity(phase: phase)
            let graph = TaskGraph(tasks: [root, child])
            XCTAssertEqual(graph.navigationTarget(for: root).id, root.id, phase.rawValue)
        }
    }

    /// 未知、未运行和终态子任务不参与提升，尤其不能将未知父任务伪装成完成。
    func testInactiveAndUnknownChildrenNeverReplaceRootActivity() {
        for rootPhase in TaskPhase.allCases {
            let root = task("root", phase: rootPhase)
            let children = [TaskPhase.unknown, .idle, .completed, .stopped].enumerated().map {
                task("child-\($0.offset)", phase: $0.element, parent: root.id)
            }
            let graph = TaskGraph(tasks: [root] + children)
            XCTAssertEqual(graph.activitySource(for: root), root, rootPhase.rawValue)
            XCTAssertEqual(graph.activity(for: root), root.activity, rootPhase.rawValue)
        }
    }

    /// 运行、等待和失败同级时父任务优先；父任务更低级时保留输入中首个同级子任务。
    func testEveryEligibleTieKeepsRootOrFirstChildAndRespectsPassedRoot() {
        for phase in [TaskPhase.running, .waiting, .failed] {
            let root = task("root", phase: phase)
            let first = task("first", phase: phase, parent: root.id)
            let second = task("second", phase: phase, parent: root.id)
            XCTAssertEqual(TaskGraph(tasks: [root, first, second]).activitySource(for: root), root)
            let completed = task("root", phase: .completed)
            for children in [[first, second], [second, first]] {
                let graph = TaskGraph(tasks: [completed] + children)
                XCTAssertEqual(graph.activitySource(for: completed), children[0])
                XCTAssertEqual(graph.activitySource(for: root), root, "比较应尊重调用方传入的父任务活动")
            }
        }
    }
}
