import XCTest
import Foundation
@testable import CodexTopCore

/// REQ-005 设备读取接口的内容整理：全部用合成数据，不读本机记录。
final class DeviceAPITests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOverallStateFollowsOrbRules() {
        XCTAssertEqual(DeviceAPI.OverallState(paused: true, loading: true, sourceUnavailable: true, summary: .failed), .paused)
        XCTAssertEqual(DeviceAPI.OverallState(paused: false, loading: true, sourceUnavailable: true, summary: .failed), .loading)
        XCTAssertEqual(DeviceAPI.OverallState(paused: false, loading: false, sourceUnavailable: true, summary: .running), .unknown)
        XCTAssertEqual(DeviceAPI.OverallState(paused: false, loading: false, sourceUnavailable: false, summary: .waiting), .waiting)
        XCTAssertEqual(DeviceAPI.OverallState(paused: false, loading: false, sourceUnavailable: false, summary: .completed), .idle)
        XCTAssertEqual(DeviceAPI.OverallState(paused: false, loading: false, sourceUnavailable: false, summary: .unknown), .unknown)
    }

    func testStatusCountsAndKeys() throws {
        let summary = MonitorStatusSummary(phases: [.running, .running, .waiting, .failed, .completed])
        let status = DeviceAPI.status(state: .failed, summary: summary, freshDone: 2, watching: 4, finished: 47, computer: "测试电脑", now: now)
        let object = try json(DeviceAPI.encode(status))
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["generated_at_epoch"] as? Int, 1_800_000_000)
        XCTAssertEqual(object["state"] as? String, "failed")
        XCTAssertEqual(object["computer"] as? String, "测试电脑")
        let counts = try XCTUnwrap(object["counts"] as? [String: Int])
        XCTAssertEqual(counts, ["running": 2, "waiting": 1, "failed": 1, "fresh_done": 2, "watching": 4, "finished": 47])
    }

    func testTasksOrderTextAndTimes() throws {
        let waiting = TaskActivity(phase: .waiting, detail: "等待你确认", startedAt: now.addingTimeInterval(-600), waitingStartedAt: now.addingTimeInterval(-185))
        let running = TaskActivity(phase: .running, detail: "正在执行任务")
        let done = TaskActivity(phase: .completed, detail: "已完成")
        let inputs = [
            DeviceAPI.TaskInput(id: "t-active", origin: .codex, title: "进行中", activity: running, childCount: 1, section: .active),
            DeviceAPI.TaskInput(id: "t-fresh", origin: .codex, title: "刚完成", activity: done, childCount: 0, section: .fresh, freshFinishedAt: now.addingTimeInterval(-130)),
            DeviceAPI.TaskInput(id: "t-wait", origin: .claudeCode, title: "等你", activity: waiting, childCount: 2, section: .attention),
        ]
        let tasks = DeviceAPI.tasks(inputs, finishedCount: 9, titles: true, now: now)
        XCTAssertEqual(tasks.items.map(\.title), ["等你", "刚完成", "进行中"])
        XCTAssertEqual(tasks.items.map(\.section), [.attention, .fresh, .active])
        XCTAssertEqual(tasks.items[0].source, "claude_code")
        XCTAssertEqual(tasks.items[0].statusText, "等待你确认 · 2 个子任务 · 已等 3 分钟")
        XCTAssertEqual(tasks.items[1].statusText, "本轮执行已结束 · 2 分钟前")
        XCTAssertEqual(tasks.items[2].statusText, "正在执行任务 · 1 个子任务")
        XCTAssertEqual(tasks.items[0].startedAtEpoch, 1_800_000_000 - 600)
        XCTAssertEqual(tasks.items[0].waitingSinceEpoch, 1_800_000_000 - 185)
        XCTAssertFalse(tasks.hasMore)
        XCTAssertEqual(tasks.finishedCount, 9)

        // 没有可靠开始时间就写 null，不估；不在等待就没有等待开始时间。
        let object = try json(DeviceAPI.encode(tasks))
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertTrue(items[2]["started_at_epoch"] is NSNull)
        XCTAssertTrue(items[2]["waiting_since_epoch"] is NSNull)
        XCTAssertEqual(Set(items[0].keys), ["id", "source", "title", "phase", "section", "status_text", "started_at_epoch", "waiting_since_epoch"])
        XCTAssertEqual(items[0]["id"] as? String, DeviceAPI.taskCode("t-wait"))
        XCTAssertEqual(object["has_more"] as? Bool, false)
        XCTAssertEqual(object["finished_count"] as? Int, 9)
    }

    func testTitlesOffTruncationAndLimit() throws {
        let long = String(repeating: "长", count: 60)
        let inputs = (0..<25).map { DeviceAPI.TaskInput(id: "t\($0)", origin: .codex, title: $0 == 0 ? long : "任务\($0)", activity: TaskActivity(phase: .running, detail: "正在执行任务"), childCount: 0, section: .active) }
        let titled = DeviceAPI.tasks(inputs, finishedCount: 0, titles: true, now: now)
        XCTAssertEqual(titled.items.count, 20)
        XCTAssertTrue(titled.hasMore)
        XCTAssertEqual(titled.items[0].title?.count, 40)
        XCTAssertTrue(titled.items[0].title?.hasSuffix("…") == true)

        let hidden = DeviceAPI.tasks(inputs, finishedCount: 0, titles: false, now: now)
        let text = String(decoding: DeviceAPI.encode(hidden), as: UTF8.self)
        XCTAssertFalse(text.contains("\"title\""))
        XCTAssertFalse(text.contains("任务1"))
        XCTAssertTrue(text.contains("\"titles\":false"))
    }

    func testUsageQuotaWindowsAndBreakdown() throws {
        let quota = QuotaSnapshot(observedAt: now.addingTimeInterval(-60), windows: [
            QuotaWindow(minutes: 300, usedPercent: 25, resetsAt: now.addingTimeInterval(3_600)),
            QuotaWindow(minutes: 10080, usedPercent: 100),
            QuotaWindow(minutes: 60, usedPercent: 10),
        ])
        var codex = CodexUsageSummary.empty
        codex.days[6] = CodexTokens(input: 1_000, cached: 800, output: 300, reasoning: 100)
        codex.days[5] = CodexTokens(input: 50, output: 50)
        let usage = DeviceAPI.usage(quota: quota, codex: codex, claude: nil, now: now,
                                    boundary: UsageDayBoundary(timeZone: TimeZone(identifier: "UTC")!, hour: 12))
        XCTAssertEqual(usage.dayStartsAtHour, 12)
        XCTAssertEqual(usage.codex.quota.windows.map(\.kind), ["five_hour", "week"])
        XCTAssertEqual(usage.codex.quota.windows.map(\.remainingPercent), [75, 0])
        XCTAssertNil(usage.codex.quota.windows[1].resetsAtEpoch)
        XCTAssertTrue(usage.codex.quota.available)
        let today = usage.codex.today
        XCTAssertEqual(today.input + today.cached + today.output + today.reasoning, today.total)
        XCTAssertEqual([today.input, today.cached, today.output, today.reasoning], [200, 800, 200, 100])
        XCTAssertEqual(usage.codex.yesterdayTotal, 100)
        XCTAssertEqual(usage.codex.days.count, 7)
        // 没有每天起点时按中午 12 点倒推：最后一天的起点是今天中午。
        let noon = UsageDayBoundary(timeZone: TimeZone(identifier: "UTC")!, hour: 12).start(of: now)
        XCTAssertEqual(usage.codex.days.last?.startEpoch, Int(noon.timeIntervalSince1970))
        XCTAssertFalse(usage.claudeCode.available)

        let object = try json(DeviceAPI.encode(usage))
        XCTAssertNotNil(object["claude_code"])
        let claude = try XCTUnwrap(object["claude_code"] as? [String: Any])
        XCTAssertNotNil((claude["today"] as? [String: Any])?["cache_read"])
    }

    func testMissingQuotaIsMarked() throws {
        let usage = DeviceAPI.usage(quota: nil, codex: nil, claude: ClaudeUsageSummary.empty, now: now)
        XCTAssertFalse(usage.codex.quota.available)
        let quota = try XCTUnwrap(try json(DeviceAPI.encode(usage))["codex"] as? [String: Any])["quota"] as? [String: Any]
        XCTAssertTrue(quota?["observed_at_epoch"] is NSNull)
        XCTAssertTrue(usage.claudeCode.available)
    }

    /// 短编号：同一任务稳定、不同任务不同、12 位十六进制、不含原编号。
    func testTaskCodeIsStableAndOpaque() {
        let id = "019a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8"
        let code = DeviceAPI.taskCode(id)
        XCTAssertEqual(code, DeviceAPI.taskCode(id))
        XCTAssertNotEqual(code, DeviceAPI.taskCode(id + "x"))
        XCTAssertEqual(code.count, 12)
        XCTAssertTrue(code.allSatisfy(\.isHexDigit))
        XCTAssertFalse(id.contains(code))
        XCTAssertFalse(code.contains("019a"))
    }

    func testThemeAndOpenResult() throws {
        let theme = try json(DeviceAPI.encode(DeviceAPI.theme(choice: .system, effectiveIsDark: false, now: now)))
        XCTAssertEqual(theme["choice"] as? String, "system")
        XCTAssertEqual(theme["effective"] as? String, "light")
        XCTAssertEqual(theme["schema_version"] as? Int, 1)
        XCTAssertEqual(try json(DeviceAPI.encode(DeviceAPI.OpenResult(opened: true))) as NSDictionary, ["opened": true] as NSDictionary)
        let failed = try json(DeviceAPI.encode(DeviceAPI.OpenResult(opened: false, message: "无法打开")))
        XCTAssertEqual(failed["opened"] as? Bool, false)
        XCTAssertEqual(failed["message"] as? String, "无法打开")
    }

    func testTokenIsSixDigitsAndChecked() {
        for _ in 0..<50 {
            let token = DeviceAPI.newToken()
            XCTAssertEqual(token.count, 6)
            XCTAssertTrue(token.allSatisfy(\.isNumber))
        }
        XCTAssertTrue(DeviceAPI.tokenMatches(authorization: "Bearer 012345", token: "012345"))
        XCTAssertTrue(DeviceAPI.tokenMatches(authorization: "bearer 012345", token: "012345"))
        XCTAssertFalse(DeviceAPI.tokenMatches(authorization: "Bearer 012346", token: "012345"))
        XCTAssertFalse(DeviceAPI.tokenMatches(authorization: nil, token: "012345"))
        XCTAssertFalse(DeviceAPI.tokenMatches(authorization: "012345", token: "012345"))
        XCTAssertFalse(DeviceAPI.tokenMatches(authorization: "Bearer 012345", token: nil))
    }

    func testStatusTextMatchesPanelPieces() {
        let start = now.addingTimeInterval(-30)
        XCTAssertEqual(TaskStatusText.finished(at: start, now: now), "本轮执行已结束 · 刚刚")
        XCTAssertEqual(TaskStatusText.waited(since: start, now: now), "· 已等 1 分钟")
        XCTAssertNil(TaskStatusText.children(0))
        XCTAssertEqual(TaskStatusText.children(3), "· 3 个子任务")
    }
}
