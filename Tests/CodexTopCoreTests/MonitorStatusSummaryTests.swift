import XCTest
@testable import CodexTopCore

final class MonitorStatusSummaryTests: XCTestCase {
    func testAttentionKeepsTheConcurrentRunningCount() {
        let status = MonitorStatusSummary(phases: [.running, .running, .waiting, .completed])
        XCTAssertEqual(status.phase, .waiting)
        XCTAssertEqual(status.running, 2)
        XCTAssertEqual(status.attention, 1)
        let failed = MonitorStatusSummary(phases: [.running, .waiting, .failed])
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.running, 1)
        XCTAssertEqual(failed.attention, 2)
    }
    func testGreenRequiresAllMonitoredTasksToComplete() {
        XCTAssertEqual(MonitorStatusSummary(phases: [.completed, .unknown]).phase, .unknown)
        XCTAssertEqual(MonitorStatusSummary(phases: [.completed, .idle]).phase, .idle)
        XCTAssertEqual(MonitorStatusSummary(phases: [.completed, .stopped]).phase, .stopped)
        XCTAssertEqual(MonitorStatusSummary(phases: []).phase, .idle)
        XCTAssertEqual(MonitorStatusSummary(phases: [.completed, .completed]).phase, .completed)
    }
}
