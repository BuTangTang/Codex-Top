import AppKit
import XCTest
@testable import CodexTop

/// D-88：刻度顺时针转（用户 2026-11-09 要求），编号越大越晚变亮。
@MainActor final class TickSpinnerTests: XCTestCase {
    func testTicksAreNumberedClockwiseFromTwelveOClock() throws {
        let view = TickSpinnerView()
        view.layout()
        XCTAssertEqual(view.ticks.count, 12)
        func outerEnd(_ index: Int) throws -> CGPoint {
            var end = CGPoint.zero
            try XCTUnwrap(view.ticks[index].path).applyWithBlock { element in
                if element.pointee.type == .addLineToPoint { end = element.pointee.points[0] }
            }
            return end
        }
        let top = try outerEnd(0), next = try outerEnd(1)
        XCTAssertEqual(top.x, 22, accuracy: 0.01)
        XCTAssertLessThan(top.y, 22, "视图向下为正，0 号在 12 点")
        XCTAssertGreaterThan(next.x, 22, "1 号在 0 号的顺时针一侧（右上）")
        XCTAssertLessThan(next.y, 22)
    }

    func testStillGradientTrailsCounterclockwiseBehindTheBrightestTick() {
        XCTAssertEqual(TickSpinnerView.gradientOpacity(0), 1)
        XCTAssertGreaterThan(TickSpinnerView.gradientOpacity(11), TickSpinnerView.gradientOpacity(10), "尾巴在逆时针一侧逐根变暗")
        XCTAssertEqual(TickSpinnerView.gradientOpacity(1), TickSpinnerView.dimmest, accuracy: 0.001, "顺时针前方那根最暗")
    }

    func testSpinningStartsLaterTicksLaterSoTheHighlightMovesClockwise() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 44, height: 44), styleMask: .borderless, backing: .buffered, defer: false)
        let view = TickSpinnerView()
        window.contentView = view
        view.update(color: .systemBlue, spinning: true, gradient: true, opacity: 1)
        let first = try XCTUnwrap(view.ticks[0].animation(forKey: TickSpinnerView.animationKey))
        let second = try XCTUnwrap(view.ticks[1].animation(forKey: TickSpinnerView.animationKey))
        XCTAssertEqual(second.beginTime - first.beginTime, TickSpinnerView.period / 12, accuracy: 0.0001)
        view.update(color: .systemBlue, spinning: false, gradient: true, opacity: 1)
        XCTAssertNil(view.ticks[0].animation(forKey: TickSpinnerView.animationKey))
    }
}
