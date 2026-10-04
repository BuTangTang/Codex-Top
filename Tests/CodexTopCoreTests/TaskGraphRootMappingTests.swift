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
