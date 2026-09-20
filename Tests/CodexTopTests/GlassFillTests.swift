import AppKit
import SwiftUI
import XCTest
@testable import CodexTop

final class GlassFillTests: XCTestCase {
    @MainActor
    func testDarkSurfaceHasNoNativeGlassBeforeOrAfterThemeChange() async throws {
        let state = SurfaceTheme()
        let host = NSHostingView(rootView: SurfaceHarness(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 308, height: 109),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(backdrops(in: host), 0)
        state.light = true
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(backdrops(in: host), 1)
        state.light = false
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(backdrops(in: host), 0)
        window.setContentSize(CGSize(width: 308, height: 217))
        window.setContentSize(CGSize(width: 308, height: 109))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(backdrops(in: host), 0)
        XCTAssertFalse(window.isVisible)
    }
    @MainActor private func backdrops(in view: NSView) -> Int {
        (view is NSVisualEffectView ? 1 : 0) + view.subviews.reduce(0) { $0 + backdrops(in: $1) }
    }
}

@MainActor private final class SurfaceTheme: ObservableObject {
    @Published var light = false
}
private struct SurfaceHarness: View {
    @ObservedObject var state: SurfaceTheme
    var body: some View {
        GlassFill().environment(\.colorScheme, state.light ? .light : .dark)
            .transaction { $0.disablesAnimations = true }
    }
}
