import XCTest
import CodexTopCore
@testable import CodexTop

/// REQ-003 设计第 6 节：第一次出现 Claude Code 会话时只把正在运行或等待的加入关注，其余记为基线。
final class ClaudeBaselineTests: XCTestCase {
    private func task(_ id: String, _ phase: TaskPhase) -> CodexTask {
        var task = CodexTask(id: id, title: id, project: "p", createdAt: .now, updatedAt: .now,
                             rolloutURL: URL(fileURLWithPath: "/synthetic.jsonl"), origin: .claudeCode)
        task.activity = TaskActivity(phase: phase)
        return task
    }

    func testFirstAppearanceSelectsActiveAndBaselinesTheRest() {
        var preferences = MonitorPreferences()
        preferences.initialized = true; preferences.autoBaselineIDs = ["codex-old"]; preferences.excludedIDs = ["cc:hidden"]
        TaskStore.applyClaudeBaseline(&preferences, claudeTasks: [task("cc:run", .running), task("cc:ask", .waiting),
                                                                    task("cc:done", .completed), task("cc:hidden", .running)])
        XCTAssertEqual(preferences.selectedIDs, ["cc:run", "cc:ask"])
        XCTAssertEqual(preferences.autoBaselineIDs, ["codex-old", "cc:run", "cc:ask", "cc:done", "cc:hidden"])
        XCTAssertEqual(preferences.claudeBaselineApplied, true)

        // 只做一次；之后的新会话按原有自动关注规则处理。
        TaskStore.applyClaudeBaseline(&preferences, claudeTasks: [task("cc:new", .running)])
        XCTAssertFalse(preferences.autoBaselineIDs?.contains("cc:new") == true)
    }

    func testNoSessionsOrFirstLaunchLeaveRulesToReconcile() {
        var preferences = MonitorPreferences()
        TaskStore.applyClaudeBaseline(&preferences, claudeTasks: [])
        XCTAssertNil(preferences.claudeBaselineApplied, "还没出现会话时不记基线")
        TaskStore.applyClaudeBaseline(&preferences, claudeTasks: [task("cc:run", .running)])
        XCTAssertEqual(preferences.claudeBaselineApplied, true)
        XCTAssertTrue(preferences.selectedIDs.isEmpty, "首次启动由 reconcile 统一处理")
    }

    func testOldPreferencesWithoutClaudeFieldsStillDecode() throws {
        let data = try JSONEncoder().encode(MonitorPreferences())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["claudeEnabled", "claudeHome", "claudeBaselineApplied"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(MonitorPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.resolvedClaudeEnabled, "旧设置默认开启 Claude Code 来源")
    }
}
