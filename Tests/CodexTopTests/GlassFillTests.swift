import AppKit
import SwiftUI
import XCTest
@testable import CodexTop

final class GlassFillTests: XCTestCase {
    @MainActor
    func testBothSurfacesStayOpaqueWithoutNativeGlassAcrossThemeAndSizeChanges() async throws {
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
        try assertSurface(in: host, white: 0)
        state.light = true
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(backdrops(in: host), 0)
        try assertSurface(in: host, white: 0.98)
        state.light = false
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(backdrops(in: host), 0)
        try assertSurface(in: host, white: 0)
        window.setContentSize(CGSize(width: 308, height: 217))
        window.setContentSize(CGSize(width: 308, height: 109))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(backdrops(in: host), 0)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testPreparedAndReplacedThemeSnapshotsContainNoNativeGlass() async throws {
        let state = SurfaceTheme()
        state.light = true
        let host = NSHostingView(rootView: SurfaceHarness(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 308, height: 109),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let reveal = ThemeReveal()
        defer { reveal.cancel(); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(reveal.prepare(window: window, oldTheme: .light, pointInWindow: CGPoint(x: 12, y: 12),
                                     cornerRadius: 20, squareTop: false, circularCorners: false))
        XCTAssertEqual(backdrops(in: host), 0)
        try assertSurface(in: host, white: 0.98)

        state.light = false
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        // Replacing a prepared reveal must preserve its visible old image,
        // without reintroducing the previous behind-window glass approximation.
        XCTAssertTrue(reveal.prepare(window: window, oldTheme: .dark, pointInWindow: CGPoint(x: 12, y: 12),
                                     cornerRadius: 20, squareTop: false, circularCorners: false))
        XCTAssertEqual(backdrops(in: host), 0)
        try assertSurface(in: host, white: 0.98)
        reveal.cancel()
        host.layoutSubtreeIfNeeded()
        try assertSurface(in: host, white: 0)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func assertSurface(in view: NSView, white: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), file: file, line: line)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, file: file, line: line)
        for channel in [color.redComponent, color.greenComponent, color.blueComponent] {
            XCTAssertEqual(channel, white, accuracy: 0.01, file: file, line: line)
        }
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
