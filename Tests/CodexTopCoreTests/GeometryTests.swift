import XCTest
import CoreGraphics
@testable import CodexTopCore

final class GeometryTests: XCTestCase {
    func testNotchLayoutLeavesCameraWidthAndUsesLogicalCoordinates() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let top = WindowGeometry.compact(screen: screen, visible: screen.insetBy(dx: 0, dy: 32), notchWidth: 180, notchHeight: 32)
        XCTAssertEqual(top.midX, screen.midX)
        XCTAssertEqual(top.maxY, screen.maxY)
        XCTAssertEqual(top.width, 376)
    }
    func testExternalDisplayLeftAndAboveMainDoesNotJumpToOrigin() {
        let screen = CGRect(x: -2560, y: 400, width: 2560, height: 1440)
        let visible = CGRect(x: -2560, y: 440, width: 2560, height: 1370)
        let top = WindowGeometry.compact(screen: screen, visible: visible, notchWidth: 0, notchHeight: 0)
        XCTAssertEqual(top.midX, -1280)
        XCTAssertLessThan(top.maxY, visible.maxY)
        XCTAssertTrue(visible.contains(top))
    }
    func testUnpluggedOrOversizedWindowIsClampedToRemainingDisplay() {
        let visible = CGRect(x: 0, y: 40, width: 1280, height: 730)
        let restored = WindowGeometry.clamp(CGRect(x: -2200, y: 2000, width: 400, height: 900), to: visible)
        XCTAssertTrue(visible.contains(restored))
        let normalized = WindowGeometry.floating(size: CGSize(width: 400, height: 300), visible: visible, x: .nan, y: 3)
        XCTAssertTrue(visible.contains(normalized))
    }
    func testExpandedNotchPreservesCameraAnchorAtFullAndReducedScale() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 910)
        let compact = WindowGeometry.compact(screen: screen, visible: visible, notchWidth: 180, notchHeight: 32)
        for scale in [CGFloat(0.8), 0.9, 1] {
            let frame = WindowGeometry.expanded(from: compact, size: CGSize(width: 410 * scale, height: 380 * scale), visible: visible)
            XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.001)
            XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001)
            XCTAssertEqual(frame.width, 410 * scale, accuracy: 0.001)
        }
    }
    func testDockZoneDoesNotCaptureOtherScreensOrTheMiddleOfTheDesktop() {
        let visible = CGRect(x: -1280, y: 40, width: 1280, height: 730)
        XCTAssertTrue(WindowGeometry.shouldDock(CGRect(x: -800, y: 624, width: 288, height: 134), to: visible))
        XCTAssertFalse(WindowGeometry.shouldDock(CGRect(x: -800, y: 400, width: 288, height: 134), to: visible))
        XCTAssertFalse(WindowGeometry.shouldDock(CGRect(x: 200, y: 624, width: 288, height: 134), to: visible))
        XCTAssertFalse(WindowGeometry.shouldDock(CGRect(x: -800, y: 1240, width: 288, height: 134), to: visible))
    }
    func testExpandedExternalCapsuleKeepsItsAnchorWithinAShortNegativeCoordinateScreen() {
        let screen = CGRect(x: -1280, y: -800, width: 1280, height: 800)
        let visible = CGRect(x: -1280, y: -760, width: 1280, height: 735)
        let compact = WindowGeometry.compact(screen: screen, visible: visible, notchWidth: 0, notchHeight: 0)
        let expanded = WindowGeometry.expanded(from: compact, size: CGSize(width: 410, height: 2000), visible: visible)
        XCTAssertEqual(expanded.maxY, compact.maxY)
        XCTAssertEqual(expanded.midX, compact.midX)
        XCTAssertTrue(visible.contains(expanded))
    }
}
