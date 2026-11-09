import XCTest
@testable import CodexTopCore

/// D-89：LED 点阵排版。所有点必须落在整数点上（两块屏都不糊），外圈顺时针排、四角整像素圆角。
final class LEDOrbLayoutTests: XCTestCase {
    private func layout(running: Int = 0, waiting: Int = 0, failed: Int = 0, done: Bool = false, unknown: Bool = false) -> LEDOrbLayout.Layout {
        LEDOrbLayout.layout(LEDOrbLayout.groups(running: running, waiting: waiting, failed: failed, allDone: done, unknown: unknown))
    }

    func testGroupsShowOnlyWhatExists() {
        XCTAssertEqual(LEDOrbLayout.groups(running: 3, waiting: 0, failed: 0, allDone: false, unknown: false).map(\.text), ["3"])
        XCTAssertEqual(LEDOrbLayout.groups(running: 2, waiting: 1, failed: 4, allDone: false, unknown: false).map(\.tone), [.running, .waiting, .failed])
        XCTAssertEqual(LEDOrbLayout.groups(running: 0, waiting: 2, failed: 0, allDone: false, unknown: false).map(\.tone), [.idle, .waiting])
        XCTAssertEqual(LEDOrbLayout.groups(running: 0, waiting: 0, failed: 0, allDone: true, unknown: false).map(\.text), ["✓"])
        XCTAssertEqual(LEDOrbLayout.groups(running: 5, waiting: 1, failed: 0, allDone: false, unknown: true).map(\.text), ["?"], "暂停或无法判断不伪装成运行")
        XCTAssertEqual(LEDOrbLayout.groups(running: 120, waiting: 0, failed: 0, allDone: false, unknown: false).map(\.text), ["99+"])
    }

    func testEverythingSitsOnWholePoints() {
        for value in [layout(running: 3), layout(running: 12, waiting: 10, failed: 3), layout(running: 120, waiting: 1)] {
            let rects = value.dots.map(\.rect) + value.dividers + value.ring
            for rect in rects {
                XCTAssertEqual(rect.minX, rect.minX.rounded(), "\(rect)")
                XCTAssertEqual(rect.minY, rect.minY.rounded(), "\(rect)")
            }
            XCTAssertEqual(value.width, value.width.rounded())
            XCTAssertTrue(rects.allSatisfy { $0.minX >= 0 && $0.maxX <= value.width && $0.minY >= 0 && $0.maxY <= LEDOrbLayout.height })
        }
    }

    func testWidthGrowsWithGroupsAndStartsAt45() {
        XCTAssertEqual(layout(running: 3).width, 45)
        XCTAssertEqual(layout(done: true).width, 45)
        XCTAssertGreaterThan(layout(running: 2, waiting: 1, failed: 1).width, layout(running: 2, waiting: 1).width)
        XCTAssertEqual(Int(layout(running: 12, waiting: 10).width - 9) % 4, 0, "两条直边上的灯正好 4 点一格")
    }

    func testRingRunsClockwiseWithRoundedPixelCorners() throws {
        let ring = layout(running: 3).ring
        XCTAssertEqual(ring.count, 36)
        let centers = ring.map { CGPoint(x: $0.midX, y: $0.midY) }
        // 从左上直边起：先向右，再向下，再向左，再向上
        XCTAssertGreaterThan(centers[1].x, centers[0].x)
        let topRight = try XCTUnwrap(centers.firstIndex { $0.y == 5.5 && $0.x > 22 })
        XCTAssertEqual(centers[topRight].x, 45 - 5.5, "右上角那颗往里收 1 点")
        XCTAssertGreaterThan(centers[topRight + 1].y, centers[topRight].y, "过了右上角往下走")
        for index in centers.indices {
            let next = centers[(index + 1) % centers.count]
            let distance = hypot(next.x - centers[index].x, next.y - centers[index].y)
            XCTAssertGreaterThanOrEqual(distance, 3, "相邻两颗不重叠")
            XCTAssertLessThanOrEqual(distance, 4.001, "过角时不跳格")
        }
    }

    func testDividersSitBetweenGroups() {
        let value = layout(running: 2, waiting: 1, failed: 1)
        XCTAssertEqual(value.dividers.count, 2)
        let waitingDots = value.dots.filter { $0.tone == .waiting }.map(\.rect.minX)
        XCTAssertLessThan(value.dividers[0].maxX, waitingDots.min()!)
    }
}
