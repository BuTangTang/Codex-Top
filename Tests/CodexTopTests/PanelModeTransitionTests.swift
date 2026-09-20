import AppKit
import XCTest
@testable import CodexTop

final class PanelModeTransitionTests: XCTestCase {
    @MainActor
    func testRapidModeChoiceOnlyAppliesLastRequestAndRestoresInput() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Reduce Motion settles changes immediately") }
        let window = makeWindow()
        defer { window.close() }
        let transition = PanelModeTransition()
        var applied: [String] = [], completed: [String] = []
        transition.run(windows: [window], animated: true) { applied.append("orb") } completion: { completed.append("orb") }
        XCTAssertTrue(transition.isActive)
        XCTAssertTrue(window.ignoresMouseEvents)
        try await Task.sleep(for: .milliseconds(30))
        transition.run(windows: [window], animated: true) { applied.append("floating") } completion: { completed.append("floating") }
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(applied, ["floating"])
        XCTAssertEqual(completed, ["floating"])
        XCTAssertFalse(transition.isActive)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testDisplayRecoveryFinishesPendingModeOnce() async throws {
        let window = makeWindow()
        defer { window.close() }
        let transition = PanelModeTransition()
        var applied = 0, completed = 0
        transition.run(windows: [window], animated: true) { applied += 1 } completion: { completed += 1 }
        transition.finish()
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(completed, 1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(transition.isActive)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testInitialLayoutDoesNotDelayOrFadeTheWindow() {
        let window = makeWindow()
        defer { window.close() }
        let transition = PanelModeTransition()
        var applied = false
        transition.run(windows: [window], animated: false) { applied = true }
        XCTAssertTrue(applied)
        XCTAssertFalse(transition.isActive)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 270, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
