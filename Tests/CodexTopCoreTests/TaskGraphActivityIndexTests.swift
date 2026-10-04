import Foundation
import XCTest
@testable import CodexTopCore

final class TaskGraphActivityIndexTests: XCTestCase {
    /// 用原来的过滤后取最小值规则对照所有阶段组合和输入顺序，不依赖索引实现。
    func testAllRootAndChildPhasesPreserveOriginalSelectionInBothOrders() {
        for rootPhase in TaskPhase.allCases {
            let root = task("root", phase: rootPhase)
            for firstPhase in TaskPhase.allCases {
                let first = task("first", phase: firstPhase, parent: root.id)
                for secondPhase in TaskPhase.allCases {
                    let second = task("second", phase: secondPhase, parent: root.id)
                    for ordered in [[first, second], [second, first]] {
                        let graph = TaskGraph(tasks: [root] + ordered)
                        assertOriginalBehavior(graph, for: root)
                    }
                }
            }
        }
    }

    /// 图内父任务可能已经过时；调用者提供的活动和其他字段必须继续作为本次比较依据。
    func testEveryPassedRootPhaseIsComparedInsteadOfStoredRootPhase() {
        for storedPhase in TaskPhase.allCases {
            let stored = task("root", phase: storedPhase)
            for childPhase in TaskPhase.allCases {
                let child = task("child", phase: childPhase, parent: stored.id)
                let graph = TaskGraph(tasks: [stored, child])
                for passedPhase in TaskPhase.allCases {
                    var passed = task("root", phase: passedPhase)
                    passed.title = "Updated caller value"
                    passed.activity.detail = "caller activity"
                    passed.activity.startedAt = Date(timeIntervalSince1970: 1_800_000_100)
                    assertOriginalBehavior(graph, for: passed)
                    if childPhase.priority >= passedPhase.priority || !(childPhase.isActive || childPhase == .failed) {
                        XCTAssertEqual(graph.activitySource(for: passed), passed)
                    }
                }
            }
        }
    }

    /// 没有可用子任务或查询的根不在图里时，应原样返回调用者，不推断新状态。
    func testEmptyGraphsAndRootsWithoutChildrenReturnCallerValue() {
        for phase in TaskPhase.allCases {
            let root = task("root", phase: phase)
            for graph in [TaskGraph(tasks: []), TaskGraph(tasks: [root])] {
                XCTAssertEqual(graph.activitySource(for: root), root)
                XCTAssertEqual(graph.activity(for: root), root.activity)
                XCTAssertEqual(graph.navigationTarget(for: root), root)
            }
            let other = task("other", phase: .completed)
            let waiting = task("waiting", phase: .waiting, parent: other.id)
            XCTAssertEqual(TaskGraph(tasks: [other, waiting]).activitySource(for: root), root)
        }
    }

    /// 同级后代保持原输入中的首项，活动时钟、详情和待处理跳转来自同一真实任务。
    func testFirstPendingDescendantSuppliesTimingDetailAndNavigation() {
        let root = task("root", phase: .completed)
        let branch = task("branch", phase: .running, parent: root.id)
        var direct = task("direct", phase: .waiting, parent: root.id)
        var descendant = task("descendant", phase: .waiting, parent: branch.id)
        direct.activity.waitingStartedAt = Date(timeIntervalSince1970: 1_800_000_020)
        descendant.activity.waitingStartedAt = Date(timeIntervalSince1970: 1_800_000_030)
        for ordered in [[descendant, root, branch, direct], [direct, root, branch, descendant]] {
            let graph = TaskGraph(tasks: ordered)
            let expected = ordered[0]
            XCTAssertEqual(graph.activitySource(for: root), expected)
            XCTAssertEqual(graph.navigationTarget(for: root), expected)
            XCTAssertEqual(graph.activity(for: root).waitingStartedAt, expected.activity.waitingStartedAt)
            XCTAssertEqual(graph.activity(for: root).startedAt, expected.activity.startedAt)
            XCTAssertEqual(graph.activity(for: root).detail, "子任务 · \(expected.activity.detail)")
            XCTAssertEqual(graph.rootIDs[descendant.id], root.id)
            assertOriginalBehavior(graph, for: root)
        }
    }

    /// 每次重建都取新快照，状态结束、恢复和换父任务不能沿用前一个图的候选。
    func testRebuildingGraphTracksCompletionResumptionAndReparenting() {
        let root = task("root", phase: .completed)
        let other = task("other", phase: .completed)
        var first = task("first", phase: .waiting, parent: root.id)
        var second = task("second", phase: .running, parent: root.id)
        let original = TaskGraph(tasks: [root, other, first, second])
        XCTAssertEqual(original.navigationTarget(for: root), first)

        first.activity.phase = .completed
        second.activity.phase = .failed
        let failed = TaskGraph(tasks: [root, other, first, second])
        XCTAssertEqual(failed.activitySource(for: root), second)
        XCTAssertEqual(failed.navigationTarget(for: root), root)
        assertOriginalBehavior(failed, for: root)

        second.activity.phase = .stopped
        let finished = TaskGraph(tasks: [root, other, first, second])
        XCTAssertEqual(finished.activitySource(for: root), root)

        first.activity.phase = .waiting
        first.parentID = other.id
        let resumed = TaskGraph(tasks: [root, other, first, second])
        XCTAssertEqual(resumed.activitySource(for: root), root)
        XCTAssertEqual(resumed.navigationTarget(for: other), first)
        XCTAssertEqual(resumed.children[root.id]?.map(\.id), [second.id])
        XCTAssertEqual(resumed.children[other.id]?.map(\.id), [first.id])
        XCTAssertEqual(original.navigationTarget(for: root).activity.phase, .waiting)
        XCTAssertEqual(original.navigationTarget(for: root).parentID, root.id)
        assertOriginalBehavior(resumed, for: root)
        assertOriginalBehavior(resumed, for: other)
    }

    /// 已有孤儿与循环归根规则保持，任何候选都不能串到别的根。
    func testMultipleRootsOrphansAndCyclesKeepTheirOwnActivitySource() {
        let root = task("root", phase: .completed)
        let child = task("child", phase: .running, parent: root.id)
        let orphan = task("orphan", phase: .unknown, parent: "missing")
        let orphanChild = task("orphan-child", phase: .failed, parent: orphan.id)
        let cycleRoot = task("cycle-a", phase: .completed, parent: "cycle-b")
        let cycleChild = task("cycle-b", phase: .waiting, parent: cycleRoot.id)
        let graph = TaskGraph(tasks: [child, orphanChild, cycleChild, root, orphan, cycleRoot])
        XCTAssertEqual(Set(graph.roots.map(\.id)), [root.id, orphan.id, cycleRoot.id])
        XCTAssertEqual(graph.activitySource(for: root), child)
        XCTAssertEqual(graph.activitySource(for: orphan), orphanChild)
        XCTAssertEqual(graph.navigationTarget(for: cycleRoot), cycleChild)
        for queried in graph.roots + [child, orphanChild, cycleChild] {
            assertOriginalBehavior(graph, for: queried)
        }
    }

    /// 原算法是行为对照基线；不读取或复制新索引，保留原过滤、同级顺序和根优先规则。
    private func originalSource(_ graph: TaskGraph, for root: CodexTask) -> CodexTask {
        let eligible = (graph.children[root.id] ?? []).filter { $0.activity.phase.isActive || $0.activity.phase == .failed }
        guard let child = eligible.min(by: { $0.activity.phase.priority < $1.activity.phase.priority }),
              child.activity.phase.priority < root.activity.phase.priority else { return root }
        return child
    }

    /// 同时验证完整任务值、聚合活动和跳转目的地，避免只比较阶段掩盖错误候选。
    private func assertOriginalBehavior(_ graph: TaskGraph, for root: CodexTask, file: StaticString = #filePath, line: UInt = #line) {
        let expected = originalSource(graph, for: root)
        XCTAssertEqual(graph.activitySource(for: root), expected, file: file, line: line)
        var activity = expected.id == root.id ? root.activity : expected.activity
        if expected.id != root.id { activity.detail = "子任务 · \(activity.detail)" }
        XCTAssertEqual(graph.activity(for: root), activity, file: file, line: line)
        XCTAssertEqual(graph.navigationTarget(for: root), expected.activity.phase == .waiting ? expected : root, file: file, line: line)
    }

    /// 全部样例只在内存中构造，不读取真实任务或写入任何运行时记录。
    private func task(_ id: String, phase: TaskPhase, parent: String? = nil) -> CodexTask {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var result = CodexTask(id: id, title: id, project: "Synthetic", createdAt: now, updatedAt: now,
                               parentID: parent, rolloutURL: URL(fileURLWithPath: "/synthetic/\(id).jsonl"))
        result.activity = TaskActivity(phase: phase, detail: "activity \(id)", lastEventAt: now,
                                       startedAt: now.addingTimeInterval(-10), waitingStartedAt: now)
        result.activity.turnID = "turn-\(id)"
        return result
    }
}
