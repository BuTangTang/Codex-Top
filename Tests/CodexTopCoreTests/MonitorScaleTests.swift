import XCTest
import Foundation
@testable import CodexTopCore

final class MonitorScaleTests: XCTestCase {
    private let scales = stride(from: 60, through: 120, by: 5).map { Double($0) / 100 }
    private let coordinateAccuracy: CGFloat = 0.0001

    func testScaleDefaultsAndBounds() {
        XCTAssertEqual(MonitorScale.minimum, 0.6)
        XCTAssertEqual(MonitorScale.maximum, 1.2)
        XCTAssertEqual(MonitorScale.step, 0.05)
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(MonitorScale.normalized(value), 1)
        }
        for value in [-Double.greatestFiniteMagnitude, -1, 0, 0.59] {
            XCTAssertEqual(MonitorScale.normalized(value), 0.6)
        }
        for value in [1.21, 2, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(MonitorScale.normalized(value), 1.2)
        }
    }

    func testEveryScaleAndHalfStepSnapIsStable() {
        XCTAssertEqual(scales.count, 13)
        for scale in scales {
            XCTAssertEqual(MonitorScale.normalized(scale), scale)
            XCTAssertEqual(MonitorScale.normalized(MonitorScale.normalized(scale)), scale)
            XCTAssertEqual(MonitorScale.normalized(scale - 0.024), scale)
            XCTAssertEqual(MonitorScale.normalized(scale + 0.024), scale)
        }
        for (index, midpointPercent) in stride(from: 62.5, through: 117.5, by: 5).enumerated() {
            let midpoint = midpointPercent / 100
            XCTAssertEqual(MonitorScale.normalized(midpoint), scales[index + 1], "Halfway values round up")
            XCTAssertEqual(MonitorScale.normalized(midpoint - 0.000_001), scales[index])
            XCTAssertEqual(MonitorScale.normalized(midpoint + 0.000_001), scales[index + 1])
        }
    }

    func testPreferencesNormalizeWithoutChangingLegacySelections() throws {
        var preferences = MonitorPreferences()
        preferences.selectedIDs = ["kept-task"]
        XCTAssertEqual(preferences.resolvedScale, 1)
        for scale in scales {
            preferences.uiScale = scale
            let restored = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.resolvedScale, scale)
            XCTAssertEqual(restored.selectedIDs, ["kept-task"])
        }
        for value in [Double.nan, .infinity, -.infinity, -1, 0.724, 1.076, 2] {
            preferences.uiScale = value
            XCTAssertEqual(preferences.resolvedScale, MonitorScale.normalized(value))
        }
    }

    func testAllScaleNotchEndpointsShareWidthAndPreserveCameraSpace() {
        let displays: [(screen: CGRect, visible: CGRect, camera: CGSize)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900),
             CGRect(x: 72, y: 40, width: 1368, height: 828), CGSize(width: 200, height: 32)),
            (CGRect(x: -1280, y: -800, width: 1280, height: 800),
             CGRect(x: -1280, y: -760, width: 1280, height: 735), .zero)
        ]
        for display in displays {
            for scale in scales {
                let frames = WindowGeometry.topPanelFrames(screen: display.screen, visible: display.visible,
                    scaledSize: CGSize(width: 410 * scale, height: 344 * scale + display.camera.height),
                    notchWidth: display.camera.width, notchHeight: display.camera.height)
                XCTAssertEqual(frames.compact.minX, frames.expanded.minX)
                XCTAssertEqual(frames.compact.width, frames.expanded.width)
                XCTAssertEqual(frames.compact.maxY, frames.expanded.maxY, accuracy: coordinateAccuracy)
                XCTAssertTrue(display.screen.contains(frames.expanded))
                XCTAssertGreaterThanOrEqual(frames.expanded.minX, display.visible.minX + 8)
                XCTAssertLessThanOrEqual(frames.expanded.maxX, display.visible.maxX - 8)
                XCTAssertGreaterThanOrEqual(frames.expanded.minY, display.visible.minY + 8)
                if display.camera.width > 0 {
                    let camera = CGRect(x: display.screen.midX - display.camera.width / 2,
                        y: display.screen.maxY - display.camera.height,
                        width: display.camera.width, height: display.camera.height)
                    XCTAssertTrue(frames.compact.contains(camera))
                    XCTAssertEqual(frames.compact.height, display.camera.height)
                } else {
                    XCTAssertTrue(display.visible.contains(frames.expanded))
                }
            }
        }
    }

    func testAllScaleOrbPanelsFitAndKeep44PointReturnTarget() {
        for visible in [CGRect(x: -1280, y: -760, width: 1280, height: 735),
                        CGRect(x: 0, y: 40, width: 460, height: 320)] {
            for x in [0.0, 0.5, 1.0] {
                for y in [0.0, 0.5, 1.0] {
                    let orb = WindowGeometry.floating(size: CGSize(width: 44, height: 44), visible: visible, x: x, y: y)
                    for scale in scales {
                        let opened = WindowGeometry.orbPanelLayout(from: orb,
                            size: CGSize(width: 410 * scale, height: 344 * scale), visible: visible)
                        XCTAssertTrue(visible.contains(opened.frame))
                        // Subtracting and re-adding a fractional height can leave a
                        // shared edge a few ULPs apart. Still check every containment edge.
                        XCTAssertGreaterThanOrEqual(orb.minX, opened.frame.minX - coordinateAccuracy)
                        XCTAssertGreaterThanOrEqual(orb.minY, opened.frame.minY - coordinateAccuracy)
                        XCTAssertLessThanOrEqual(orb.maxX, opened.frame.maxX + coordinateAccuracy)
                        XCTAssertLessThanOrEqual(orb.maxY, opened.frame.maxY + coordinateAccuracy)
                        let resized = WindowGeometry.resizedOrbPanel(from: opened.frame,
                            size: CGSize(width: 410 * scale, height: 600 * scale), visible: visible,
                            direction: opened.direction)
                        let returnTarget = WindowGeometry.movingOrbAnchor(orb, from: opened.frame,
                            to: resized, direction: opened.direction)
                        XCTAssertTrue(visible.contains(resized))
                        XCTAssertTrue(resized.contains(returnTarget))
                        XCTAssertEqual(returnTarget.size, CGSize(width: 44, height: 44))
                        XCTAssertEqual(returnTarget.minX, orb.minX, accuracy: coordinateAccuracy)
                        XCTAssertEqual(returnTarget.minY, orb.minY, accuracy: coordinateAccuracy)
                    }
                }
            }
        }
    }
}
