import XCTest
@testable import CodexTopCore

final class TaskGraphRootMappingTests: XCTestCase {
    /// 无父项、缺失父项、自环和多节点环保持各自归根，输入顺序不改变唯一编号的关系。
    func testRootsOrphansAndCyclesKeepTheirOriginalResolution() {
        let tasks = [task("plain"), task("orphan", parent: "missing"), task("orphan-child", parent: "orphan"),
                     task("self", parent: "self"), task("cycle-b", parent: "cycle-a"),
                     task("cycle-a", parent: "cycle-b"), task("descendant", parent: "cycle-b")]
        let expected = ["plain": "plain", "orphan": "orphan", "orphan-child": "orphan", "self": "self",
                        "cycle-a": "cycle-a", "cycle-b": "cycle-a", "descendant": "cycle-a"]
        for ordering in [tasks, Array(tasks.reversed()), Array(tasks.dropFirst(3)) + tasks.prefix(3)] {
            assertMapping(ordering, expected: expected)
        }
    }

    /// 重复编号仍由最先输入的父关系决定，展示成员保持全部原始记录及其顺序。
    func testFirstDuplicateControlsParentageWithoutDroppingMembers() {
        let first = task("duplicate", parent: "a", title: "第一项")
        let second = task("duplicate", parent: "b", title: "第二项")
        let a = task("a"), b = task("b"), child = task("child", parent: "duplicate")
        assertMapping([first, child, a, second, b], expected: ["duplicate": "a", "child": "a", "a": "a", "b": "b"])
        assertMapping([second, child, b, first, a], expected: ["duplicate": "b", "child": "b", "a": "a", "b": "b"])
        let standalone = task("duplicate", title: "独立根")
        assertMapping([standalone, first, a, child], expected: ["duplicate": "duplicate", "a": "a", "child": "duplicate"])
    }

    /// 每次调用只使用当前输入，改父项、删除父项及恢复不能沿用先前图的关系。
    func testRebuildingReflectsChangedAndMissingParents() {
        let a = task("a"), b = task("b")
        var child = task("child", parent: "a")
        let original = TaskGraph(tasks: [child, a, b])
        assertMapping([child, a, b], expected: ["child": "a", "a": "a", "b": "b"])
        child.parentID = "b"
        assertMapping([child, a, b], expected: ["child": "b", "a": "a", "b": "b"])
        assertMapping([child, a], expected: ["child": "child", "a": "a"])
        child.parentID = nil
        assertMapping([child, a, b], expected: ["child": "child", "a": "a", "b": "b"])
        XCTAssertEqual(original.rootIDs["child"], "a")
    }

    /// 空输入和长链沿用同一归根规则，不引入深度截断或任务活动依赖。
    func testEmptyAndDeepChainsResolveInBothInputOrders() {
        assertMapping([], expected: [:])
        let tasks = (0..<120).map { index in task("node-\(index)", parent: index == 0 ? nil : "node-\(index - 1)") }
        let expected = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, "node-0") })
        assertMapping(tasks, expected: expected)
        assertMapping(Array(tasks.reversed()), expected: expected)
    }

    /// 交错根、孤儿、环与重复编号，旋转及逆序同时覆盖 nil 父项先来和非 nil 父项先来。
    func testLegacyOracleKeepsAllMembersOrderAndActivityAcrossMixedBoundaries() {
        let input = [task("child-a", parent: "a"), task("duplicate"), task("b"),
                     task("duplicate", parent: "b", title: "后来的父项"), task("descendant", parent: "duplicate"),
                     task("cycle-b", parent: "cycle-a"), task("a"), task("cycle-a", parent: "cycle-b"),
                     task("second-a", parent: "a"), task("orphan", parent: "missing"),
                     task("orphan-child", parent: "orphan"), task("self", parent: "self")]
        for phaseOffset in TaskPhase.allCases.indices {
            let tasks = input.enumerated().map { index, task in
                var value = task
                value.activity = TaskActivity(phase: TaskPhase.allCases[(index + phaseOffset) % TaskPhase.allCases.count],
                                              detail: "合成活动-\(index)", startedAt: Date(timeIntervalSince1970: Double(index)))
                value.activity.turnID = "turn-\(index)"
                return value
            }
            for split in tasks.indices {
                let ordering = Array(tasks[split...]) + tasks[..<split]
                assertLegacyGraph(ordering)
                assertLegacyGraph(Array(ordering.reversed()))
            }
        }
    }

    /// 固定种子只生成合成元数据；完整值对照包含空编号、Unicode 等价编号和多次重复。
    func testLegacyOracleMatchesDeterministicDuplicateAndUnicodeInputs() {
        let ids = ["", "a", "b", "重复", "é", "e\u{301}", "环-a", "环-b", "leaf", "root"]
        var state: UInt64 = 0x91
        func next(_ count: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(count))
        }
        assertLegacyGraph([])
        for snapshot in 0..<48 {
            let tasks = (0..<64).map { index in
                let id = ids[next(ids.count)]
                let parentIndex = next(ids.count + 2)
                let parent = parentIndex == ids.count ? nil : parentIndex > ids.count ? "missing" : ids[parentIndex]
                var value = task(id, parent: parent, title: "合成快照-\(snapshot)-\(index)")
                value.activity = TaskActivity(phase: TaskPhase.allCases[next(TaskPhase.allCases.count)],
                                              detail: "合成详情-\(index)", startedAt: Date(timeIntervalSince1970: Double(index)))
                value.activity.turnID = "turn-\(snapshot)-\(index)"
                return value
            }
            assertLegacyGraph(tasks)
            assertLegacyGraph(Array(tasks.reversed()))
        }
    }

    /// build90（ee02531）的数组构建及归根逻辑作为迁移 oracle，不调用当前归根实现。
    private func legacyGraph(_ tasks: [CodexTask]) -> (rootIDs: [String: String], roots: [CodexTask], children: [String: [CodexTask]]) {
        struct ParentReference { let parentID: String? }
        let lookup = Dictionary(tasks.map { ($0.id, ParentReference(parentID: $0.parentID)) }, uniquingKeysWith: { first, _ in first })
        var resolved: [String: String] = [:]
        for task in tasks {
            var current = task.id, path: [String] = [], positions: [String: Int] = [:]
            while resolved[current] == nil, positions[current] == nil, let item = lookup[current] {
                positions[current] = path.count; path.append(current)
                guard let parent = item.parentID, lookup[parent] != nil else { break }
                current = parent
            }
            let root: String
            if let known = resolved[current] { root = known }
            else if let cycleStart = positions[current], path.last != current { root = path[cycleStart...].min() ?? current }
            else { root = current }
            for id in path { resolved[id] = root }
        }
        return (resolved, tasks.filter { resolved[$0.id] == $0.id },
                Dictionary(grouping: tasks.filter { resolved[$0.id] != $0.id }) { resolved[$0.id] ?? $0.id })
    }

    /// 对照完整成员和活动来源；错误归根、同级覆盖或跨根混入不能被阶段相同掩盖。
    private func assertLegacyGraph(_ tasks: [CodexTask], file: StaticString = #filePath, line: UInt = #line) {
        let expected = legacyGraph(tasks), graph = TaskGraph(tasks: tasks)
        XCTAssertEqual(TaskGraph.resolveRootIDs(tasks: tasks), expected.rootIDs, file: file, line: line)
        XCTAssertEqual(graph.rootIDs, expected.rootIDs, file: file, line: line)
        XCTAssertEqual(graph.roots, expected.roots, file: file, line: line)
        XCTAssertEqual(graph.children, expected.children, file: file, line: line)
        for root in expected.roots {
            let eligible = (expected.children[root.id] ?? []).filter { $0.activity.phase.isActive || $0.activity.phase == .failed }
            let child = eligible.min { $0.activity.phase.priority < $1.activity.phase.priority }
            let source = child.flatMap { $0.activity.phase.priority < root.activity.phase.priority ? $0 : nil } ?? root
            XCTAssertEqual(graph.activitySource(for: root), source, file: file, line: line)
            var activity = source.id == root.id ? root.activity : source.activity
            if source.id != root.id { activity.detail = "子任务 · \(activity.detail)" }
            XCTAssertEqual(graph.activity(for: root), activity, file: file, line: line)
            XCTAssertEqual(graph.navigationTarget(for: root), source.activity.phase == .waiting ? source : root, file: file, line: line)
        }
    }

    /// 同时检查公开图的根及成员顺序，不只验证内部映射值。
    private func assertMapping(_ tasks: [CodexTask], expected: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        let graph = TaskGraph(tasks: tasks)
        XCTAssertEqual(TaskGraph.resolveRootIDs(tasks: tasks), expected, file: file, line: line)
        XCTAssertEqual(graph.rootIDs, expected, file: file, line: line)
        XCTAssertEqual(graph.roots, tasks.filter { expected[$0.id] == $0.id }, file: file, line: line)
        for root in Set(expected.values) {
            XCTAssertEqual(graph.children[root] ?? [], tasks.filter { $0.id != root && expected[$0.id] == root }, file: file, line: line)
        }
    }

    /// 所有输入只包含合成元数据，不读取文件、偏好或真实任务。
    private func task(_ id: String, parent: String? = nil, title: String = "合成任务") -> CodexTask {
        CodexTask(id: id, title: title, project: "合成项目", createdAt: Date(timeIntervalSince1970: 1),
                  updatedAt: Date(timeIntervalSince1970: 2), parentID: parent,
                  rolloutURL: URL(fileURLWithPath: "/synthetic/rollout.jsonl"))
    }
}
