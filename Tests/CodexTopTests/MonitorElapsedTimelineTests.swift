import SwiftUI
import XCTest
@testable import CodexTop

final class MonitorElapsedTimelineTests: XCTestCase {
    /// 隐藏面板只取当前时间，不继续产生每秒唤醒；低频模式也不例外。
    func testHiddenScheduleHasOnlyItsInitialValue() {
        let now = Date(timeIntervalSince1970: 1_000)
        for mode in [TimelineScheduleMode.normal, .lowFrequency] {
            let dates = MonitorElapsedTimelineSchedule(active: false).entries(from: now, mode: mode).makeIterator()
            XCTAssertEqual(dates.next(), now)
            XCTAssertNil(dates.next())
            XCTAssertNil(dates.next())
        }
    }

    /// 显示中的计时沿用系统原有周期计划，包括系统请求低频更新时的行为。
    func testVisibleScheduleMatchesOriginalOneSecondSchedule() {
        let now = Date(timeIntervalSince1970: 1_000.25)
        for mode in [TimelineScheduleMode.normal, .lowFrequency] {
            let expected = Array(PeriodicTimelineSchedule(from: now, by: 1).entries(from: now, mode: mode).prefix(5))
            let actual = Array(MonitorElapsedTimelineSchedule(active: true).entries(from: now, mode: mode).prefix(5))
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual, (0..<5).map { now.addingTimeInterval(Double($0)) })
        }
    }

    /// 再展开从新的当前时间开始，不补发隐藏期间的旧秒表刻度。
    func testReopeningStartsAtCurrentTimeWithoutReplayingHiddenTicks() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let closedAt = started.addingTimeInterval(5)
        let reopenedAt = started.addingTimeInterval(125)
        let hidden = MonitorElapsedTimelineSchedule(active: false).entries(from: closedAt, mode: .normal)
        XCTAssertEqual(Array(hidden.prefix(2)), [closedAt])
        let resumed = Array(MonitorElapsedTimelineSchedule(active: true).entries(from: reopenedAt, mode: .normal).prefix(2))
        XCTAssertEqual(resumed, [reopenedAt, reopenedAt.addingTimeInterval(1)])
        XCTAssertEqual(Int(try XCTUnwrap(resumed.first).timeIntervalSince(started)), 125)
    }
}
