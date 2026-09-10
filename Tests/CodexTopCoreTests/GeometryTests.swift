import XCTest
import CoreGraphics
@testable import CodexTopCore

final class GeometryTests: XCTestCase {
    func testOrbPrefersDownwardOpeningWithPointerNearHeaderAtEveryScale() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 900)
        let orb = CGRect(x: 700, y: 600, width: 44, height: 44)
        for scale in [CGFloat(0.8), 0.9, 1] {
            let layout = WindowGeometry.orbPanelLayout(from: orb, size: CGSize(width: 410 * scale, height: 340 * scale), visible: visible)
            XCTAssertEqual(layout.direction, .down)
            XCTAssertEqual(layout.frame.maxY, orb.maxY)
            XCTAssertEqual(layout.frame.midX, orb.midX)
            XCTAssertEqual(layout.frame.height, 340 * scale)
            XCTAssertTrue(layout.frame.contains(orb))
        }
    }

    func testOrbOpeningClampsBothHorizontalEdgesOnNegativeDisplay() {
        let visible = CGRect(x: -1920, y: -1080, width: 1920, height: 1040)
        for x in [visible.minX + 8, visible.maxX - 52] {
            let orb = CGRect(x: x, y: -400, width: 44, height: 44)
            let layout = WindowGeometry.orbPanelLayout(from: orb, size: CGSize(width: 328, height: 280), visible: visible)
            XCTAssertEqual(layout.direction, .down)
            XCTAssertEqual(layout.frame.maxY, orb.maxY)
            XCTAssertTrue(layout.frame.contains(orb))
            XCTAssertGreaterThanOrEqual(layout.frame.minX, visible.minX + 8)
            XCTAssertLessThanOrEqual(layout.frame.maxX, visible.maxX - 8)
        }
    }

    func testOrbNearBottomOpensUpAndKeepsThatEdgeWhenContentShrinks() {
        let visible = CGRect(x: -1280, y: -800, width: 1280, height: 760)
        let orb = CGRect(x: -600, y: visible.minY + 40, width: 44, height: 44)
        let layout = WindowGeometry.orbPanelLayout(from: orb, size: CGSize(width: 328, height: 280), visible: visible)
        XCTAssertEqual(layout.direction, .up)
        XCTAssertEqual(layout.frame.minY, orb.minY)
        XCTAssertEqual(layout.frame.height, 280)
        XCTAssertTrue(layout.frame.contains(orb))
        let smaller = WindowGeometry.resizedOrbPanel(from: layout.frame, size: CGSize(width: 328, height: 60), visible: visible, direction: layout.direction)
        XCTAssertEqual(smaller.minY, layout.frame.minY)
        XCTAssertEqual(smaller.height, 60)
        XCTAssertEqual(smaller.minX, layout.frame.minX)
    }

    func testOversizedOrbPanelChoosesLargerSideAndCapsViewport() {
        let visible = CGRect(x: 0, y: 40, width: 1280, height: 720)
        for (y, expectedDirection) in [(CGFloat(200), OrbExpansionDirection.up), (CGFloat(500), .down)] {
            let orb = CGRect(x: 600, y: y, width: 44, height: 44)
            let layout = WindowGeometry.orbPanelLayout(from: orb, size: CGSize(width: 410, height: 2000), visible: visible)
            XCTAssertEqual(layout.direction, expectedDirection)
            XCTAssertTrue(visible.contains(layout.frame))
            XCTAssertTrue(layout.frame.contains(orb))
            if expectedDirection == .down {
                XCTAssertEqual(layout.frame.maxY, orb.maxY)
                XCTAssertEqual(layout.frame.minY, visible.minY + 8)
            } else {
                XCTAssertEqual(layout.frame.minY, orb.minY)
                XCTAssertEqual(layout.frame.maxY, visible.maxY - 8)
            }
        }
    }

    func testOpenOrbKeepsChosenDownwardDirectionWhenGrowingWouldPreferUp() {
        let visible = CGRect(x: 0, y: 40, width: 1280, height: 720)
        let orb = CGRect(x: 600, y: 200, width: 44, height: 44)
        let layout = WindowGeometry.orbPanelLayout(from: orb, size: CGSize(width: 328, height: 150), visible: visible)
        XCTAssertEqual(layout.direction, .down)
        let resized = WindowGeometry.resizedOrbPanel(from: layout.frame, size: CGSize(width: 328, height: 600), visible: visible, direction: layout.direction)
        XCTAssertEqual(resized.maxY, layout.frame.maxY)
        XCTAssertEqual(resized.minY, visible.minY + 8)
        XCTAssertLessThan(resized.height, 600)
    }

    func testOpenOrbPanelDisclosureKeepsHeaderAtEveryScaleAndReturnsToOriginalSize() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 900)
        let orb = CGRect(x: 700, y: 600, width: 44, height: 44)
        for scale in [CGFloat(0.8), 0.9, 1] {
            let initial = WindowGeometry.expandedOrb(from: orb, size: CGSize(width: 410 * scale, height: 190 * scale), visible: visible)
            let expanded = WindowGeometry.resizedOrbPanel(from: initial, size: CGSize(width: initial.width, height: 340 * scale), visible: visible)
            XCTAssertEqual(expanded.maxY, initial.maxY, accuracy: 0.001)
            XCTAssertEqual(expanded.minX, initial.minX, accuracy: 0.001)
            XCTAssertEqual(expanded.height, 340 * scale, accuracy: 0.001)
            XCTAssertLessThan(expanded.minY, initial.minY)
            XCTAssertEqual(WindowGeometry.resizedOrbPanel(from: expanded, size: initial.size, visible: visible), initial)
        }
    }

    func testOpenOrbPanelOnNegativeDisplayCapsBottomWithoutMovingHeader() {
        let visible = CGRect(x: -1920, y: -1080, width: 1920, height: 1040)
        let initial = CGRect(x: -800, y: -900, width: 328, height: 152)
        let expanded = WindowGeometry.resizedOrbPanel(from: initial, size: CGSize(width: 328, height: 600), visible: visible)
        XCTAssertEqual(expanded.maxY, initial.maxY)
        XCTAssertEqual(expanded.minX, initial.minX)
        XCTAssertEqual(expanded.minY, visible.minY + 8)
        XCTAssertLessThan(expanded.height, 600)
        XCTAssertTrue(visible.contains(expanded))
        XCTAssertEqual(WindowGeometry.resizedOrbPanel(from: expanded, size: initial.size, visible: visible), initial)
    }

    func testOpenOrbPanelResizeRecoversUnreachableHeaderAndWidth() {
        let visible = CGRect(x: -1280, y: 40, width: 1280, height: 720)
        let oldDisplayPanel = CGRect(x: 400, y: 1500, width: 410, height: 400)
        let restored = WindowGeometry.resizedOrbPanel(from: oldDisplayPanel, size: CGSize(width: 2000, height: 2000), visible: visible)
        XCTAssertEqual(restored.maxY, visible.maxY - 8)
        XCTAssertEqual(restored.minY, visible.minY + 8)
        XCTAssertEqual(restored.minX, visible.minX + 8)
        XCTAssertEqual(restored.maxX, visible.maxX - 8)
        XCTAssertTrue(visible.contains(restored))
    }

    func testTopNotchEndpointsShareWidthAndPreserveCameraAtEveryScale() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for dockWidth in [CGFloat(0), 72] {
            let visible = CGRect(x: dockWidth, y: 40, width: screen.width - dockWidth, height: 910)
            for cameraWidth in [CGFloat(180), 300] {
                let camera = CGRect(x: screen.midX - cameraWidth / 2, y: 950, width: cameraWidth, height: 32)
                for scale in [CGFloat(0.8), 0.9, 1] {
                    let size = CGSize(width: 410 * scale, height: 340 * scale + camera.height)
                    let frames = WindowGeometry.topPanelFrames(screen: screen, visible: visible, scaledSize: size, notchWidth: camera.width, notchHeight: camera.height)
                    XCTAssertEqual(frames.compact.minX, frames.expanded.minX, accuracy: 0.001)
                    XCTAssertEqual(frames.compact.width, frames.expanded.width, accuracy: 0.001)
                    XCTAssertEqual(frames.compact.maxY, frames.expanded.maxY, accuracy: 0.001)
                    XCTAssertEqual(frames.compact.midX, screen.midX, accuracy: 0.001)
                    XCTAssertTrue(frames.compact.contains(camera))
                    XCTAssertTrue(frames.expanded.contains(camera))
                    XCTAssertGreaterThanOrEqual(frames.expanded.width, size.width)
                    XCTAssertGreaterThanOrEqual(frames.compact.width - camera.width, 176)
                    XCTAssertEqual(frames.expanded.height - camera.height, 340 * scale, accuracy: 0.001)
                }
            }
        }
    }

    func testExternalTopEndpointsUseOneScaledWidthAtNegativeCoordinates() {
        let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: -1040, width: 1920, height: 1016)
        for scale in [CGFloat(0.8), 0.9, 1] {
            let frames = WindowGeometry.topPanelFrames(screen: screen, visible: visible, scaledSize: CGSize(width: 410 * scale, height: 340 * scale), notchWidth: 0, notchHeight: 0)
            XCTAssertEqual(frames.compact.width, frames.expanded.width, accuracy: 0.001)
            XCTAssertEqual(frames.expanded.width / scale, 410, accuracy: 0.001)
            XCTAssertEqual(frames.compact.midX, visible.midX, accuracy: 0.001)
            XCTAssertEqual(frames.compact.minX, frames.expanded.minX, accuracy: 0.001)
            XCTAssertEqual(frames.compact.maxY, frames.expanded.maxY, accuracy: 0.001)
            XCTAssertTrue(visible.contains(frames.compact))
            XCTAssertTrue(visible.contains(frames.expanded))
        }
    }

    func testConstrainedTopEndpointsShrinkTogetherWithoutMovingCameraCenter() {
        let screen = CGRect(x: -600, y: 200, width: 600, height: 800)
        let visible = CGRect(x: -520, y: 240, width: 520, height: 728)
        let camera = CGRect(x: screen.midX - 100, y: 968, width: 200, height: 32)
        let frames = WindowGeometry.topPanelFrames(screen: screen, visible: visible, scaledSize: CGSize(width: 800, height: 2000), notchWidth: camera.width, notchHeight: camera.height)
        XCTAssertEqual(frames.compact.width, frames.expanded.width, accuracy: 0.001)
        XCTAssertEqual(frames.compact.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(frames.expanded.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(frames.compact.maxY, frames.expanded.maxY, accuracy: 0.001)
        XCTAssertTrue(frames.compact.contains(camera))
        XCTAssertTrue(frames.expanded.contains(camera))
        XCTAssertGreaterThanOrEqual(frames.expanded.minX, visible.minX + 8)
        XCTAssertLessThanOrEqual(frames.expanded.maxX, visible.maxX - 8)
        XCTAssertGreaterThanOrEqual(frames.expanded.minY, visible.minY + 8)
        XCTAssertLessThan(frames.expanded.width, 800)
    }

    func testStatusAnchorReadsProviderAfterDisplayRearrangement() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 836)
        var external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        var button = CGRect(x: 3180, y: 1056, width: 72, height: 24)
        var reads = 0
        let provider: () -> CGRect? = { reads += 1; return button }
        XCTAssertEqual(WindowGeometry.statusPanelAnchor(provider: provider, screenFrames: [main, external], fallbackVisible: visible), button)

        // The same live provider now reports the button after its display moved left.
        external.origin.x = -1920
        button.origin.x = -180
        let resolved = WindowGeometry.statusPanelAnchor(provider: provider, screenFrames: [main, external], fallbackVisible: visible)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(resolved, button)
        XCTAssertTrue(external.contains(resolved))
    }

    func testUnavailableStatusAnchorFallsBackWithoutReusingPreviousCoordinates() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 836)
        let fallback = CGRect(x: 708, y: 876, width: 24, height: 24)
        var button: CGRect? = CGRect(x: 1200, y: 876, width: 72, height: 24)
        let provider: () -> CGRect? = { button }
        XCTAssertEqual(WindowGeometry.statusPanelAnchor(provider: provider, screenFrames: [main], fallbackVisible: visible), button)

        button = nil
        XCTAssertEqual(WindowGeometry.statusPanelAnchor(provider: provider, screenFrames: [main], fallbackVisible: visible), fallback)
        button = CGRect(x: 3200, y: 1056, width: 72, height: 24) // Detached display's stale button.
        XCTAssertEqual(WindowGeometry.statusPanelAnchor(provider: provider, screenFrames: [main], fallbackVisible: visible), fallback)
        XCTAssertEqual(WindowGeometry.statusPanelAnchor(provider: nil, screenFrames: [main], fallbackVisible: visible), fallback) // Before statusItem creation.

        button = CGRect(x: 1000, y: 876, width: 72, height: 24)
        XCTAssertEqual(WindowGeometry.statusPanelAnchor(provider: provider, screenFrames: [main], fallbackVisible: visible), button)
    }

    func testScaledOrbNoticeEndpointsAreStableOnOneAndTwoTimesDisplays() {
        let visible = CGRect(x: -1920, y: -1080, width: 1920, height: 1040)
        let orb = CGRect(x: -600, y: -400, width: 44, height: 44)
        for backing in [CGFloat(1), 2] {
            for uiScale in [CGFloat(0.8), 0.9, 1] {
                for logicalHeight in [CGFloat(335), 387] {
                    let raw = WindowGeometry.expandedOrb(from: orb, size: CGSize(width: 410 * uiScale, height: logicalHeight * uiScale), visible: visible)
                    let aligned = WindowGeometry.pixelAligned(raw, scale: backing)
                    XCTAssertTrue(visible.contains(aligned))
                    XCTAssertTrue(aligned.contains(orb))
                    for value in [aligned.minX, aligned.minY, aligned.width, aligned.height] {
                        XCTAssertEqual(value * backing, (value * backing).rounded(), accuracy: 0.0001)
                    }
                    XCTAssertEqual(aligned, WindowGeometry.pixelAligned(aligned, scale: backing))
                    XCTAssertLessThanOrEqual(abs(aligned.height - raw.height), 0.5 / backing + 0.0001)
                }
            }
        }
    }
    func testNotchLayoutLeavesCameraWidthAndUsesLogicalCoordinates() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let top = WindowGeometry.compact(screen: screen, visible: screen.insetBy(dx: 0, dy: 32), notchWidth: 180, notchHeight: 32)
        XCTAssertEqual(top.midX, screen.midX)
        XCTAssertEqual(top.maxY, screen.maxY)
        XCTAssertEqual(top.width, 356)
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
    func testDraggingOpenOrbPanelMovesItsReturnPointOnNegativeCoordinates() {
        let oldPanel = CGRect(x: -1500, y: -800, width: 328, height: 260)
        let newPanel = oldPanel.offsetBy(dx: 350, dy: 210)
        for direction in [OrbExpansionDirection.down, .up] {
            let orb = CGRect(x: -1370, y: direction == .down ? oldPanel.maxY - 44 : oldPanel.minY, width: 44, height: 44)
            let moved = WindowGeometry.movingOrbAnchor(orb, from: oldPanel, to: newPanel, direction: direction)
            XCTAssertEqual(moved, orb.offsetBy(dx: 350, dy: 210))
            XCTAssertTrue(newPanel.contains(moved))
            XCTAssertEqual(moved.size, CGSize(width: 44, height: 44))
        }
    }

    func testDroppingDownwardPanelOnSmallerDisplayKeepsOrbOnHeaderEdge() {
        let oldPanel = CGRect(x: -1500, y: -800, width: 410, height: 600)
        let orb = CGRect(x: oldPanel.maxX - 44, y: oldPanel.maxY - 44, width: 44, height: 44)
        let newPanel = CGRect(x: 8, y: 48, width: 328, height: 300)
        let moved = WindowGeometry.movingOrbAnchor(orb, from: oldPanel, to: newPanel, direction: .down)
        XCTAssertEqual(moved.maxY, newPanel.maxY)
        XCTAssertEqual(moved.maxX, newPanel.maxX)
        XCTAssertEqual(moved.size, CGSize(width: 44, height: 44))
        XCTAssertTrue(newPanel.contains(moved))
    }

    func testDroppingUpwardPanelOnSmallerDisplayKeepsOrbOnBottomEdge() {
        let oldPanel = CGRect(x: 500, y: 48, width: 410, height: 600)
        let orb = CGRect(x: 660, y: oldPanel.minY, width: 44, height: 44)
        let newPanel = CGRect(x: -920, y: -500, width: 328, height: 300)
        let moved = WindowGeometry.movingOrbAnchor(orb, from: oldPanel, to: newPanel, direction: .up)
        XCTAssertEqual(moved.minY, newPanel.minY)
        XCTAssertEqual(moved.minX, orb.minX + newPanel.minX - oldPanel.minX)
        XCTAssertEqual(moved.size, CGSize(width: 44, height: 44))
        XCTAssertTrue(newPanel.contains(moved))
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
    func testOrbExpansionKeepsOriginalCircleInsideThePanelAtAllScreenEdges() {
        let visible = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
        for x in [visible.minX + 8, visible.midX, visible.maxX - 52] {
            for y in [visible.minY + 8, visible.midY, visible.maxY - 52] {
                let orb = CGRect(x: x, y: y, width: 44, height: 44)
                for scale in [CGFloat(0.8), 0.9, 1] {
                    let expanded = WindowGeometry.expandedOrb(from: orb, size: CGSize(width: 410 * scale, height: 344 * scale), visible: visible)
                    XCTAssertTrue(visible.contains(expanded))
                    XCTAssertTrue(expanded.contains(orb))
                }
            }
        }
    }

    func testScreenChangeKeepsAReachableUtilityWindowOnItsOtherDisplay() {
        let main = CGRect(x: 0, y: 40, width: 1280, height: 720)
        let external = CGRect(x: -1600, y: 40, width: 1600, height: 900)
        let frame = CGRect(x: -1300, y: 120, width: 500, height: 610)
        XCTAssertEqual(WindowGeometry.recoverUtilityWindow(frame, visibleFrames: [main, external], preferredVisible: main), frame)
    }

    func testPartlyOffscreenUtilityWindowUsesItsLargestVisibleIntersection() {
        let main = CGRect(x: 0, y: 40, width: 1280, height: 720)
        let external = CGRect(x: -1600, y: 40, width: 1600, height: 900)
        let frame = CGRect(x: -300, y: 700, width: 500, height: 610)
        let restored = WindowGeometry.recoverUtilityWindow(frame, visibleFrames: [main, external], preferredVisible: main)
        XCTAssertTrue(external.contains(restored))
        XCTAssertEqual(restored.size, frame.size)
        XCTAssertFalse(main.intersects(restored))
    }

    func testDisconnectedUtilityWindowFallsBackToChosenDisplay() {
        let main = CGRect(x: 0, y: 40, width: 1280, height: 720)
        let frame = CGRect(x: 3000, y: 2000, width: 500, height: 610)
        let restored = WindowGeometry.recoverUtilityWindow(frame, visibleFrames: [main], preferredVisible: main)
        XCTAssertTrue(main.contains(restored))
        XCTAssertEqual(restored.size, frame.size)
    }

    func testExplicitRecoveryBringsAnOtherwiseVisibleUtilityWindowToChosenDisplay() {
        let main = CGRect(x: 0, y: 40, width: 1280, height: 720)
        let external = CGRect(x: -1600, y: 40, width: 1600, height: 900)
        let frame = CGRect(x: -1300, y: 120, width: 500, height: 610)
        let restored = WindowGeometry.recoverUtilityWindow(frame, visibleFrames: [main, external], preferredVisible: main, forcePreferred: true)
        XCTAssertTrue(main.contains(restored))
        XCTAssertEqual(restored.size, frame.size)
    }

}
