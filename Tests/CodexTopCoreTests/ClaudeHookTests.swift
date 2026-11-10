import XCTest
import Foundation
@testable import CodexTopCore

/// REQ-003 层 C：钩子事件和 settings.json 编辑，只用临时目录里的合成文件。
final class ClaudeHookTests: XCTestCase {
    private var directory: URL!
    private var settings: URL { directory.appendingPathComponent("settings.json") }
    private var backups: URL { directory.appendingPathComponent("backups") }
    private let helper = URL(fileURLWithPath: "/Users/x/Library/Application Support/Codex Top/bin/codex-top-claude-hook")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func input(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    func testRecordKeepsOnlyKindAndTime() throws {
        let events = directory.appendingPathComponent("events")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        ClaudeHookEvents.record(input: input(["hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "abc-1",
                                              "message": "secret", "cwd": "/secret", "transcript_path": "/secret"]), directory: events, now: at)
        ClaudeHookEvents.record(input: input(["hook_event_name": "Notification", "notification_type": "idle_prompt", "session_id": "abc-1"]), directory: events)
        ClaudeHookEvents.record(input: input(["hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "../x"]), directory: events)
        let text = try String(contentsOf: events.appendingPathComponent("abc-1.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertEqual(text.split(separator: "\n").count, 1, "只记批准和填写两种")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: events.path), ["abc-1.jsonl"])
        XCTAssertEqual(ClaudeHookEvents.latest(directory: events, session: "abc-1"), ClaudeHookEvent(kind: "permission_prompt", at: at))
    }

    func testEventNewerThanTranscriptMeansWaiting() {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        let running = TaskActivity(phase: .running, detail: "正在调用工具", lastEventAt: last)
        let waiting = ClaudeHookEvents.apply(ClaudeHookEvent(kind: "permission_prompt", at: last.addingTimeInterval(1)), to: running)
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertEqual(waiting.detail, "等待你批准")
        XCTAssertEqual(ClaudeHookEvents.apply(ClaudeHookEvent(kind: "permission_prompt", at: last.addingTimeInterval(-1)), to: running), running,
                       "批准后记录有了更新的行，就回到运行")
        let completed = TaskActivity(phase: .completed, detail: "本轮执行已结束", lastEventAt: last)
        XCTAssertEqual(ClaudeHookEvents.apply(ClaudeHookEvent(kind: "permission_prompt", at: last.addingTimeInterval(1)), to: completed), completed)
    }

    func testInstallIntoHandwrittenFileKeepsEverythingElse() throws {
        let original = """
        {
          "permissions": {
            "allow": ["Bash(ls)"]
          },

          "hooks": {
            "Stop": [
              { "hooks": [{ "type": "command", "command": "say done" }] }
            ]
          }
        }

        """
        try Data(original.utf8).write(to: settings)
        try ClaudeHookInstaller.install(settings: settings, helper: helper, backups: backups)
        let installed = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(installed.hasPrefix(String(original.prefix(original.count - 16))), "前面的内容原样保留")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(installed.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(value["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"])
        let entry = try XCTUnwrap((hooks["Notification"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["matcher"] as? String, "permission_prompt|elicitation_dialog")
        XCTAssertEqual(ClaudeHookInstaller.isInstalled(settings: settings, helper: helper), true)
        try ClaudeHookInstaller.install(settings: settings, helper: helper, backups: backups)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), installed, "再装一次不重复")
        try ClaudeHookInstaller.remove(settings: settings, helper: helper, backups: backups)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original, "移除后和原来一字不差")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testOtherNotificationHooksStayAndOldHelperPathIsReplaced() throws {
        let old = URL(fileURLWithPath: "/Users/old/Library/Application Support/Codex Top/bin/codex-top-claude-hook")
        let original = "{\n  \"hooks\": {\n    \"Notification\": [\n      {\n        \"hooks\": [{ \"type\": \"command\", \"command\": \"say hi\" }]\n      }\n    ]\n  }\n}\n"
        try Data(original.utf8).write(to: settings)
        try ClaudeHookInstaller.install(settings: settings, helper: old, backups: backups)
        try ClaudeHookInstaller.install(settings: settings, helper: helper, backups: backups)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let list = try XCTUnwrap((value["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(ClaudeHookInstaller.isInstalled(settings: settings, helper: old), false)
        try ClaudeHookInstaller.remove(settings: settings, helper: helper, backups: backups)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
    }

    func testMissingFileIsCreatedAndRemovedAgain() throws {
        try ClaudeHookInstaller.install(settings: settings, helper: helper, backups: backups)
        XCTAssertEqual(ClaudeHookInstaller.isInstalled(settings: settings, helper: helper), true)
        try ClaudeHookInstaller.remove(settings: settings, helper: helper, backups: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path), "文件是 Codex Top 建的，移除时一起删掉")
    }

    func testInvalidJSONIsLeftAlone() throws {
        let original = "{ // comment\n  \"a\": 1\n}\n"
        try Data(original.utf8).write(to: settings)
        XCTAssertNil(ClaudeHookInstaller.isInstalled(settings: settings, helper: helper))
        XCTAssertThrowsError(try ClaudeHookInstaller.install(settings: settings, helper: helper, backups: backups))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
    }

    func testSourceShowsWaitingFromHookEvent() async throws {
        let root = directory.appendingPathComponent("claude"), events = directory.appendingPathComponent("events")
        let project = root.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let now = Date()
        func line(_ value: [String: Any], _ offset: TimeInterval) -> String {
            var value = value; value["timestamp"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
            return String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let transcript = [
            line(["type": "user", "message": ["role": "user", "content": "go"]], -5),
            line(["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use",
                                                   "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]]]], -4),
        ].joined(separator: "\n") + "\n"
        try Data(transcript.utf8).write(to: project.appendingPathComponent("s1.jsonl"))
        ClaudeHookEvents.record(input: input(["hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "s1"]),
                                directory: events, now: now.addingTimeInterval(-3))
        let source = ClaudeCodeSource(root: root, hookEvents: events, readRegistry: { _ in ClaudeSessionRegistry(entries: nil) })
        let snapshot = await source.snapshot(now: now)
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.activity.phase, .waiting)
        XCTAssertEqual(task.activity.detail, "等待你批准")
    }
}
