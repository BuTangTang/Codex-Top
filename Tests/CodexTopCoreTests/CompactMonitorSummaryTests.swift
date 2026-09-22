import XCTest
@testable import CodexTopCore

final class CompactMonitorSummaryTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testAttentionOverridesRunningAndPausedWithoutLosingFailureColor() {
        for paused in [false, true] {
            let waiting = summary([.running, .running, .waiting], paused: paused)
            XCTAssertEqual(waiting.leftText, "1 待处理")
            XCTAssertEqual(waiting.leftPhase, .waiting)
            let failed = summary([.running, .waiting, .failed], paused: paused)
            XCTAssertEqual(failed.leftText, "2 待处理")
            XCTAssertEqual(failed.leftPhase, .failed)
        }
    }

    func testPauseReplacesTheRunningCountOnlyWhenNoAttentionIsPending() {
        let paused = summary([.running, .running], paused: true)
        XCTAssertEqual(paused.leftText, "已暂停")
        XCTAssertEqual(paused.leftPhase, .idle)
        let active = summary([.running, .running, .completed])
        XCTAssertEqual(active.leftText, "2 运行中")
        XCTAssertEqual(active.leftPhase, .running)
    }

    func testInactiveStatesDistinguishEmptyFromUnstartedAndUnknownTasks() {
        let cases: [([TaskPhase], String, TaskPhase)] = [
            ([], "无任务", .idle),
            ([.idle], "未运行", .idle),
            ([.completed, .completed], "已完成", .completed),
            ([.completed, .unknown], "状态未知", .unknown),
            ([.completed, .stopped], "已停止", .stopped)
        ]
        for (phases, text, phase) in cases {
            let value = summary(phases)
            XCTAssertEqual(value.leftText, text)
            XCTAssertEqual(value.leftPhase, phase)
        }
    }

    func testQuotaShowsRemainingPercentAndSortsActualWindows() {
        let quota = QuotaSnapshot(observedAt: instant, windows: [
            QuotaWindow(minutes: 10080, usedPercent: 39),
            QuotaWindow(minutes: 300, usedPercent: 18)
        ], origin: .account)
        let value = summary([], quota: quota)
        XCTAssertEqual(value.quotaLines, ["5h 82%", "周 61%"])
        XCTAssertFalse(value.isQuotaStale)
    }

    func testMissingQuotaDoesNotInventAWindowOrBalance() {
        XCTAssertEqual(summary([]).quotaLines, ["额度暂无数据"])
        let empty = QuotaSnapshot(observedAt: instant, windows: [])
        XCTAssertEqual(summary([], quota: empty).quotaLines, ["额度暂无数据"])
        let weekly = QuotaSnapshot(observedAt: instant, windows: [QuotaWindow(minutes: 10080, usedPercent: 40)])
        XCTAssertEqual(summary([], quota: weekly).quotaLines, ["周 60%"])
    }

    func testNonstandardWindowsKeepTheirPeriodsAndOutputIsLimitedToTwoLines() {
        let quota = QuotaSnapshot(observedAt: instant, windows: [
            QuotaWindow(minutes: 10080, usedPercent: 10),
            QuotaWindow(minutes: 120, usedPercent: 12.5),
            QuotaWindow(minutes: 15, usedPercent: 105)
        ])
        XCTAssertEqual(summary([], quota: quota).quotaLines, ["15m 0%", "2h 88%"])
    }

    func testFiveMinuteAgeBoundaryMarksHistoryWithoutFabricatingNewBalance() {
        let windows = [QuotaWindow(minutes: 300, usedPercent: 20)]
        let boundary = QuotaSnapshot(observedAt: instant.addingTimeInterval(-300), windows: windows)
        let older = QuotaSnapshot(observedAt: instant.addingTimeInterval(-300.01), windows: windows)
        XCTAssertFalse(summary([], quota: boundary).isQuotaStale)
        let value = summary([], quota: older)
        XCTAssertTrue(value.isQuotaStale)
        XCTAssertEqual(value.quotaLines, ["5h 80%"])
    }

    func testResetBoundaryHidesOnlyTheExpiredPercentage() {
        let quota = QuotaSnapshot(observedAt: instant, windows: [
            QuotaWindow(minutes: 300, usedPercent: 90, resetsAt: instant),
            QuotaWindow(minutes: 10080, usedPercent: 40, resetsAt: instant.addingTimeInterval(1))
        ])
        let value = summary([], quota: quota)
        XCTAssertEqual(value.quotaLines, ["5h 待更新", "周 60%"])
        XCTAssertTrue(value.isQuotaStale)
    }

    private func summary(_ phases: [TaskPhase], paused: Bool = false, quota: QuotaSnapshot? = nil) -> CompactMonitorSummary {
        CompactMonitorSummary(status: MonitorStatusSummary(phases: phases), paused: paused, quota: quota, now: instant)
    }
}
