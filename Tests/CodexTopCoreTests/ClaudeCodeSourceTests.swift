import XCTest
import Foundation
@testable import CodexTopCore

/// REQ-003 层 A：只用合成会话记录，不读取本机真实的 Claude Code 数据。
final class ClaudeCodeSourceTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ type: String, _ extra: [String: Any] = [:]) -> Data {
        clock = clock.addingTimeInterval(1)
        var value = extra
        value["type"] = type
        value["timestamp"] = ISO8601DateFormatter().string(from: clock)
        return try! JSONSerialization.data(withJSONObject: value)
    }
    private func user(_ text: String, extra: [String: Any] = [:]) -> Data {
        line("user", extra.merging(["message": ["role": "user", "content": text]]) { $1 })
    }
    private func toolUse(_ id: String, name: String) -> Data {
        line("assistant", ["message": ["role": "assistant", "stop_reason": "tool_use",
                                       "content": [["type": "tool_use", "id": id, "name": name, "input": ["secret": "x"]]]]])
    }
    private func toolResult(_ id: String) -> Data {
        line("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }
    private func endTurn() -> Data {
        line("assistant", ["message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "done"]]]])
    }
    private func reduce(_ lines: [Data]) -> ClaudeTranscriptReducer {
        var reducer = ClaudeTranscriptReducer()
        lines.forEach { reducer.consume($0) }
        return reducer
    }

    func testPromptToolsAndCompletion() {
        let started = user("fix it", extra: ["cwd": "/work/app"])
        var reducer = reduce([started, toolUse("t1", name: "Bash")])
        XCTAssertEqual(reducer.activity.phase, .running)
        XCTAssertNotNil(reducer.activity.startedAt)
        XCTAssertEqual(reducer.workingDirectory, "/work/app")
        reducer.consume(toolResult("t1"))
        XCTAssertEqual(reducer.activity.phase, .running)
        reducer.consume(endTurn())
        XCTAssertEqual(reducer.activity.phase, .completed)
    }

    func testQuestionAndPlanWaitUntilAnswered() {
        var reducer = reduce([user("go"), toolUse("q1", name: "AskUserQuestion")])
        XCTAssertEqual(reducer.activity.phase, .waiting)
        XCTAssertEqual(reducer.activity.detail, "等待你的回答")
        XCTAssertNotNil(reducer.activity.waitingStartedAt)
        reducer.consume(toolResult("q1"))
        XCTAssertEqual(reducer.activity.phase, .running)
        reducer.consume(toolUse("p1", name: "ExitPlanMode"))
        XCTAssertEqual(reducer.activity.detail, "等待你的确认")
    }

    /// 桌面 App 收尾时带提问（wrap_up 的 ask）就是在等你确认，不能当成已结束；只有总结没有提问的仍算结束（D-87）。
    func testDesktopClosingQuestionWaitsForConfirmation() {
        func wrapUp(_ input: [String: Any]) -> Data {
            line("assistant", ["message": ["role": "assistant", "stop_reason": "tool_use",
                                           "content": [["type": "tool_use", "id": "w\(input.count)", "name": "mcp__ccd_turn__wrap_up", "input": input]]]])
        }
        var reducer = reduce([user("go"), wrapUp(["recap": "done", "ask": "装吗？", "blocked": true]), toolResult("w3"), endTurn()])
        XCTAssertEqual(reducer.activity.phase, .waiting)
        XCTAssertEqual(reducer.activity.detail, "等待你确认")
        XCTAssertNotNil(reducer.activity.waitingStartedAt)
        reducer.consume(user("装"))
        XCTAssertEqual(reducer.activity.phase, .running)
        reducer.consume(endTurn())
        XCTAssertEqual(reducer.activity.phase, .completed, "上一轮的提问不带到下一轮")
        XCTAssertEqual(reduce([user("go"), wrapUp(["recap": "done"]), toolResult("w1"), endTurn()]).activity.phase, .completed)
        XCTAssertEqual(reduce([user("go"), wrapUp(["recap": "done", "ask": "  "]), toolResult("w2"), endTurn()]).activity.phase, .completed)
        XCTAssertEqual(reduce([user("go"), wrapUp(["recap": "done", "ask": "提交吗？"]), toolResult("w2"), wrapUp(["recap": "done"]), toolResult("w1"), endTurn()]).activity.phase,
                       .completed, "带提问的收尾被退回、改成不带提问再收尾，以最后一次为准")
    }

    func testInterruptErrorAndIgnoredLines() {
        XCTAssertEqual(reduce([user("go"), user("[Request interrupted by user for tool use]")]).activity.phase, .stopped)
        let failed = reduce([user("go"), line("assistant", ["isApiErrorMessage": true, "message": ["role": "assistant", "content": []]])])
        XCTAssertEqual(failed.activity.phase, .failed)
        XCTAssertTrue(failed.activity.detail.contains("Claude Code"))
        // 子代理与元信息行不改变主会话；正文不当作标题。
        let side = reduce([user("go"), endTurn(), user("sub", extra: ["isSidechain": true]), user("meta", extra: ["isMeta": true])])
        XCTAssertEqual(side.activity.phase, .completed)
        XCTAssertNil(side.title)
    }

    func testSyntheticNoResponseDoesNotComplete() {
        let synthetic = line("assistant", ["message": ["role": "assistant", "model": "<synthetic>", "stop_reason": "end_turn",
                                                     "content": [["type": "text", "text": "No response requested."]]]])
        XCTAssertEqual(reduce([user("go"), synthetic]).activity.phase, .running)
    }

    func testTitlesPreferCustomOverSessionName() {
        let reducer = reduce([line("custom-title", ["customTitle": "My name"]), line("agent-name", ["agentName": "Auto"])])
        XCTAssertEqual(reducer.title, "My name")
        XCTAssertEqual(reduce([line("agent-name", ["agentName": "Auto"])]).title, "Auto")
    }

    func testOlderLinesAreIgnored() {
        var reducer = reduce([user("go"), endTurn()])
        clock = clock.addingTimeInterval(-100)
        reducer.consume(user("late"))
        XCTAssertEqual(reducer.activity.phase, .completed)
    }

    // MARK: 来源

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-work-app"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ lines: [Data], to url: URL, append: Bool = false) throws {
        var data = Data()
        lines.forEach { data.append($0); data.append(0x0A) }
        if append, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try handle.close()
        } else {
            try data.write(to: url)
        }
        // 测试用固定时钟；把修改时间对齐到它，避免被 30 天窗口误判为旧会话。
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: url.path)
    }

    func testMissingDirectoryIsEmptyNotAnError() async {
        let source = ClaudeCodeSource(root: FileManager.default.temporaryDirectory.appendingPathComponent("absent-" + UUID().uuidString))
        let snapshot = await source.snapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertNil(snapshot.warning)
    }

    func testSnapshotListsSessionsAndReadsIncrementally() async throws {
        let root = try temporary()
        let file = root.appendingPathComponent("projects/-work-app/abc.jsonl")
        try write([line("custom-title", ["customTitle": "Fix login"]), user("go", extra: ["cwd": "/work/app"])], to: file)
        let source = ClaudeCodeSource(root: root)
        var snapshot = await source.snapshot(now: clock)
        XCTAssertEqual(snapshot.tasks.map(\.id), ["cc:abc"])
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.origin, .claudeCode)
        XCTAssertEqual(task.title, "Fix login")
        XCTAssertEqual(task.project, "app")
        XCTAssertEqual(task.activity.phase, .running)
        XCTAssertNil(task.deepLink)

        // 没有变化时不再读；追加后只读新增部分并更新状态。
        snapshot = await source.snapshot(now: clock)
        XCTAssertEqual(snapshot.bytesRead, 0)
        try write([endTurn()], to: file, append: true)
        snapshot = await source.snapshot(now: clock)
        XCTAssertEqual(snapshot.tasks.first?.activity.phase, .completed)
        XCTAssertLessThan(snapshot.bytesRead, 400)
    }

    /// 同一会话跨项目的不同文件不得共用游标或待答状态；未变化的下一轮不应再次读取正文。
    func testDuplicateSessionFilesKeepIndependentIncrementalState() async throws {
        let root = try temporary()
        let otherProject = root.appendingPathComponent("projects/-work-other")
        try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
        let shortFile = root.appendingPathComponent("projects/-work-app/shared.jsonl")
        let longFile = otherProject.appendingPathComponent("shared.jsonl")
        let shortLines = [user("short"), toolUse("short-question", name: "AskUserQuestion")]
        let longLines = [line("file-history-snapshot", ["padding": String(repeating: "x", count: 2048)]), endTurn()]
        try write(shortLines, to: shortFile)
        try write(longLines, to: longFile)
        // 先遍历较短的待答文件，再遍历较长的已结束文件；后者不能沿用前者的待答调用编号。
        try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(1)], ofItemAtPath: shortFile.path)
        let expected = reduce(longLines).activity
        let source = ClaudeCodeSource(root: root)
        let first = await source.snapshot(now: clock)
        XCTAssertEqual(first.tasks.map(\.id), ["cc:shared"], "一个会话只输出一个任务，避免下游重复键")
        XCTAssertEqual(first.tasks.first?.activity, expected, "旧副本修改时间更晚，也不能盖过另一副本的较新事件")
        XCTAssertEqual(first.tasks.first?.rolloutURL.deletingLastPathComponent().lastPathComponent, "-work-other")
        let second = await source.snapshot(now: clock)
        XCTAssertEqual(second.bytesRead, 0, "不同大小的同名会话文件不能让游标每轮来回失效")
        XCTAssertEqual(second.tasks.map(\.id), ["cc:shared"])
        XCTAssertEqual(second.tasks.first?.activity, expected, "缓存命中不能把另一项目的待答调用编号带进来")
    }

    func testRunningGoesUnknownWhenStaleWithClaudeWording() async throws {
        let root = try temporary()
        try write([user("go")], to: root.appendingPathComponent("projects/-work-app/s1.jsonl"))
        let snapshot = await ClaudeCodeSource(root: root).snapshot(now: clock.addingTimeInterval(901))
        XCTAssertEqual(snapshot.tasks.first?.activity.phase, .unknown)
        XCTAssertEqual(snapshot.tasks.first?.activity.detail, "较久未收到新活动，请回到 Claude Code 查看")
    }

    /// 空行、CRLF 和尚未写完的行不丢事件；追加换行后才消费完整结束记录。
    func testIncrementalLinesKeepUnfinishedTailUntilNewline() async throws {
        let root = try temporary()
        let file = root.appendingPathComponent("projects/-work-app/partial.jsonl")
        try write([user("go")], to: file)
        let source = ClaudeCodeSource(root: root)
        let initial = await source.snapshot(now: clock)
        XCTAssertEqual(initial.tasks.first?.activity.phase, .running)
        let completed = endTurn()
        let split = completed.count / 2
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n\r\n".utf8) + completed.prefix(split))
        let partial = await source.snapshot(keep: ["cc:partial"], now: clock)
        XCTAssertEqual(partial.tasks.first?.activity.phase, .running)
        try handle.write(contentsOf: completed.suffix(from: split))
        let noNewline = await source.snapshot(keep: ["cc:partial"], now: clock)
        XCTAssertEqual(noNewline.tasks.first?.activity.phase, .running)
        try handle.write(contentsOf: Data("\r\n\n".utf8))
        let finished = await source.snapshot(keep: ["cc:partial"], now: clock)
        XCTAssertEqual(finished.tasks.first?.activity.phase, .completed)
        let unchanged = await source.snapshot(keep: ["cc:partial"], now: clock)
        XCTAssertEqual(unchanged.bytesRead, 0)
    }

    func testUnnamedSessionAndOldSessionsSkippedUnlessKept() async throws {
        let root = try temporary()
        let file = root.appendingPathComponent("projects/-work-app/old.jsonl")
        try write([user("go")], to: file)
        let old = Date().addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let source = ClaudeCodeSource(root: root)
        let skipped = await source.snapshot()
        XCTAssertTrue(skipped.tasks.isEmpty)
        let kept = await source.snapshot(keep: ["cc:old"])
        XCTAssertEqual(kept.tasks.first?.title, "未命名会话")
    }

    // MARK: 运行登记（层 B）

    private func registry(_ root: URL, _ entries: [[String: Any]]) throws {
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, entry) in entries.enumerated() {
            try JSONSerialization.data(withJSONObject: entry).write(to: directory.appendingPathComponent("\(index + 100).json"))
        }
        // 同目录的密钥文件不能被当作登记读取。
        try Data("not json".utf8).write(to: directory.appendingPathComponent("100.secret.key"))
    }
    private func entry(_ session: String, pid: Int, entrypoint: String = "claude-desktop-3p", host: String? = nil, name: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["sessionId": session, "pid": pid, "procStart": "Sun Nov  8 04:09:48 2026", "entrypoint": entrypoint, "status": "busy"]
        if let host { value["hostSessionId"] = host }
        if let name { value["name"] = name }
        return value
    }
    private func source(_ root: URL, alive: Set<Int32>) -> ClaudeCodeSource {
        ClaudeCodeSource(root: root) { ClaudeSessionRegistry.read(root: $0) { pid, _ in alive.contains(pid) } }
    }

    func testExitedProcessStopsRunningAndWaitingSessions() async throws {
        let root = try temporary()
        try write([user("go")], to: root.appendingPathComponent("projects/-work-app/run.jsonl"))
        try write([user("go"), toolUse("q1", name: "AskUserQuestion")], to: root.appendingPathComponent("projects/-work-app/ask.jsonl"))
        try write([user("go")], to: root.appendingPathComponent("projects/-work-app/live.jsonl"))
        try write([user("go"), endTurn()], to: root.appendingPathComponent("projects/-work-app/done.jsonl"))
        try registry(root, [entry("run", pid: 11), entry("live", pid: 12)])
        let tasks = await source(root, alive: [12]).snapshot(now: clock).tasks
        let phases = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.activity) })
        XCTAssertEqual(phases["cc:run"]?.phase, .stopped, "登记在但进程已退出")
        XCTAssertEqual(phases["cc:run"]?.detail, "会话已退出")
        XCTAssertEqual(phases["cc:ask"]?.phase, .stopped, "没有登记的等待也视为已退出")
        XCTAssertEqual(phases["cc:live"]?.phase, .running)
        XCTAssertEqual(phases["cc:done"]?.phase, .completed, "已结束的状态不受登记影响")
    }

    func testRegistryNameDeepLinkAndOldLiveSessions() async throws {
        let root = try temporary()
        let host = "local_" + UUID().uuidString.lowercased()
        let old = root.appendingPathComponent("projects/-work-app/desk.jsonl")
        try write([user("go")], to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        try write([user("go")], to: root.appendingPathComponent("projects/-work-app/term.jsonl"))
        try registry(root, [entry("desk", pid: 21, host: host, name: "登记名"), entry("term", pid: 22, entrypoint: "cli")])
        let tasks = await source(root, alive: [21, 22]).snapshot(now: clock).tasks
        let desk = try XCTUnwrap(tasks.first { $0.id == "cc:desk" }, "进程还在的会话超过 30 天也要读")
        XCTAssertEqual(desk.title, "登记名", "记录里没有标题时用登记的会话名")
        XCTAssertEqual(desk.deepLink?.absoluteString, "claude://claude.ai/epitaxy/\(host)")
        XCTAssertEqual(desk.claudeSessionID, "desk")
        let term = try XCTUnwrap(tasks.first { $0.id == "cc:term" })
        XCTAssertNil(term.deepLink, "终端会话不定位")
        XCTAssertEqual(term.claudeLaunch?.fromDesktopApp, false)
    }

    func testRegistryReadSkipsBrokenFilesAndPrefersLiveDuplicate() throws {
        let root = try temporary()
        try registry(root, [entry("same", pid: 31), entry("same", pid: 32), ["sessionId": "bad"]])
        let read = ClaudeSessionRegistry.read(root: root) { pid, _ in pid == 32 }
        XCTAssertEqual(read.entries?.count, 1)
        XCTAssertEqual(read.entries?["same"]?.pid, 32)
        XCTAssertNil(ClaudeSessionRegistry.read(root: root.appendingPathComponent("absent")).entries, "目录不存在时无法判断")
        XCTAssertFalse(ClaudeSessionRegistry.processMatches(pid: 999_999, processStart: "Sun Nov  8 04:09:48 2026"))
    }

    func testProcessStartAcceptsUTCAndLocalWriting() {
        // 2026-11-09 01:31:06 UTC = 2026-11-08 20:31:06 美东；登记见过两种写法。
        let started = Date(timeIntervalSince1970: 1_794_187_866)
        let eastern = TimeZone(identifier: "America/New_York")!
        XCTAssertTrue(ClaudeSessionRegistry.startMatches(started, "Mon Nov  9 01:31:06 2026", localZone: eastern), "桌面 App 写 UTC")
        XCTAssertTrue(ClaudeSessionRegistry.startMatches(started, "Sun Nov  8 20:31:06 2026", localZone: eastern), "本地时区写法")
        XCTAssertFalse(ClaudeSessionRegistry.startMatches(started, "Mon Nov  9 01:31:07 2026", localZone: eastern), "差一秒即为进程号被复用")
    }

    func testColdReadReachesPastLargeTrailingLines() async throws {
        let root = try temporary()
        let file = root.appendingPathComponent("projects/-work-app/big.jsonl")
        // 对话行后面跟着一条 200 KiB 的附件行，尾部 64 KiB 里看不到任何对话。
        try write([user("go"), endTurn(), line("attachment", ["attachment": String(repeating: "x", count: 200_000)])], to: file)
        let snapshot = await ClaudeCodeSource(root: root).snapshot(now: clock)
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.activity.phase, .completed)
    }
}
