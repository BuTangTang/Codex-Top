import AppKit
import XCTest
@testable import CodexTop

final class FloatingPanelResizeTests: XCTestCase {
    @MainActor
    func testBottomLimitedViewportKeepsItsTopAndFitsFractionalScreenEdges() {
        let visible = CGRect(x: 1000.25, y: -300.25, width: 1000, height: 800)
        let initial = CGRect(x: 1200, y: -220, width: 270, height: 106)
        let target = FloatingPanelResize.targetFrame(from: initial, size: CGSize(width: 270, height: 300), visible: visible)
        XCTAssertEqual(target.minX, initial.minX)
        XCTAssertEqual(target.maxY, initial.maxY)
        XCTAssertLessThan(target.height, 300)
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(target))
        for x in [visible.minX, visible.maxX - 40] {
            let nearEdge = CGRect(x: x, y: initial.minY, width: 270, height: 106)
            let fitted = FloatingPanelResize.targetFrame(from: nearEdge, size: CGSize(width: 270.3, height: 300.7), visible: visible)
            XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(fitted))
            XCTAssertEqual(fitted, FloatingPanelResize.integralTarget(fitted))
        }
    }

    @MainActor
    func testRepeatedFractionalSizesDoNotAccumulatePositionOrHeightChanges() {
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let initial = CGRect(x: 500, y: 500, width: 270, height: 106)
        let requested = CGSize(width: 270.00000000001, height: 105.75)
        var frame = initial
        for _ in 0..<100 {
            frame = FloatingPanelResize.targetFrame(from: frame, size: requested, visible: visible)
            XCTAssertEqual(frame, initial)
        }
        let expanded = FloatingPanelResize.targetFrame(from: initial, size: CGSize(width: 270, height: 213.75), visible: visible)
        XCTAssertEqual(expanded.maxY, initial.maxY)
        XCTAssertEqual(expanded.height, 214)
        XCTAssertEqual(FloatingPanelResize.targetFrame(from: expanded, size: requested, visible: visible), initial)
    }

    @MainActor
    func testFractionalTargetIsNormalizedBeforeRepeatedRefreshes() {
        let window = makeWindow()
        defer { window.close() }
        let state = FloatingResizeState()
        let resize = FloatingPanelResize(window: window, state: state, reduceMotion: { false })
        let fractional = CGRect(x: 500, y: 500.25, width: 270, height: 105.75)
        XCTAssertEqual(FloatingPanelResize.integralTarget(fractional), window.frame)
        for _ in 0..<10 { resize.resize(to: fractional, animated: true) }
        XCTAssertEqual(window.frameChanges, 0)
        XCTAssertEqual(state.size, CGSize(width: 270, height: 106))
        XCTAssertFalse(resize.isAnimating)
        XCTAssertTrue(window.hasShadow)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testDisclosureUsesOneCanvasUntilEachAnimationCompletes() async throws {
        let window = makeWindow()
        defer { window.close() }
        let state = FloatingResizeState()
        let resize = FloatingPanelResize(window: window, state: state, reduceMotion: { false })
        let small = window.frame
        let large = CGRect(x: 500, y: 392, width: 270, height: 214)
        resize.resize(to: small, animated: false)
        resize.resize(to: large, animated: true)
        XCTAssertTrue(resize.isAnimating)
        XCTAssertEqual(window.frame, large)
        XCTAssertFalse(window.hasShadow)
        let prepared = window.frameChanges
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<5 { resize.resize(to: large, animated: true) }
        XCTAssertEqual(window.frameChanges, prepared)
        XCTAssertEqual(window.frame, large)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(resize.isAnimating)
        XCTAssertTrue(window.hasShadow)
        resize.resize(to: small, animated: true)
        XCTAssertEqual(window.frame, large, "Shrinking must not resize AppKit on every animation frame")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(window.frame, large)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(window.frame, small)
        XCTAssertEqual(state.size, small.size)
        XCTAssertTrue(window.hasShadow)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testRapidRequestsConvergeAndCancelledCallbacksCannotMoveWindow() async throws {
        let window = makeWindow()
        defer { window.close() }
        let state = FloatingResizeState()
        let resize = FloatingPanelResize(window: window, state: state, reduceMotion: { false })
        let small = window.frame
        let medium = CGRect(x: 500, y: 446, width: 270, height: 160)
        let large = CGRect(x: 500, y: 392, width: 270, height: 214)
        resize.resize(to: small, animated: false)
        resize.resize(to: large, animated: true)
        resize.resize(to: medium, animated: true)
        resize.resize(to: small, animated: true)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(window.frame, small)
        XCTAssertFalse(resize.isAnimating)

        resize.resize(to: large, animated: true)
        resize.resize(to: medium, animated: true)
        resize.finish()
        XCTAssertEqual(window.frame, medium)
        XCTAssertFalse(resize.isAnimating)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(window.frame, medium)
        resize.resize(to: small, animated: true)
        resize.resize(to: large, animated: true)
        resize.cancel()
        XCTAssertEqual(window.frame, small, "Cancellation discards the queued request")
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(window.frame, small)
        XCTAssertTrue(window.hasShadow)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func makeWindow() -> ResizeCountingPanel {
        _ = NSApplication.shared
        let window = ResizeCountingPanel(contentRect: CGRect(x: 500, y: 500, width: 270, height: 106),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.frameChanges = 0
        return window
    }
}

@MainActor private final class ResizeCountingPanel: NSPanel {
    var frameChanges = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameChanges += 1
        super.setFrame(frameRect, display: flag)
    }
}
