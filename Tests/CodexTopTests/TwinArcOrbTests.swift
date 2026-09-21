import AppKit
import CodexTopCore
import QuartzCore
import XCTest
@testable import CodexTop

final class TwinArcOrbTests: XCTestCase {
    @MainActor
    func testStatesKeepRunningCountsAndNeverReportUnknownAsCompleted() throws {
        let view = TwinArcOrbView()
        let center = try textLayer("twinArc.center", in: view)
        let alert = try textLayer("twinArc.alert", in: view)
        let position = center.frame
        for (phase, count, expected, notice) in [
            (TaskPhase.running, 1, "1", ""), (.running, 99, "99", ""),
            (.running, 100, "99+", ""), (.running, Int.max, "99+", ""),
            (.running, -1, "0", ""), (.waiting, 0, "!", ""),
            (.waiting, 3, "3", "!"), (.failed, 0, "×", ""),
            (.failed, 3, "3", "×"), (.completed, 0, "✓", ""),
            (.stopped, 0, "■", ""), (.unknown, 0, "?", ""), (.idle, 0, "0", "")
        ] {
            view.update(phase: phase, runningCount: count, visible: true, dark: true, reduceMotion: false)
            XCTAssertEqual(center.string as? String, expected, "\(phase), count \(count)")
            XCTAssertEqual(alert.string as? String, notice)
            XCTAssertEqual(alert.isHidden, notice.isEmpty)
            XCTAssertEqual(center.frame, position, "State and count changes must not move the central number")
            XCTAssertEqual(view.frame.size, NSSize(width: 44, height: 44))
        }
        XCTAssertEqual(center.fontSize, 17)
    }

    @MainActor
    func testBothArcsHaveFixedGeometryAndNoFullTrack() throws {
        let view = TwinArcOrbView()
        view.update(phase: .running, runningCount: 1, visible: false, dark: true, reduceMotion: false)
        let rotor = try layer("twinArc.rotor", in: view)
        let arcs = try XCTUnwrap(rotor.sublayers as? [CAGradientLayer])
        XCTAssertEqual(arcs.count, 2, "Only the two fixed arcs belong to the rotating container")
        for arc in arcs {
            let mask = try XCTUnwrap(arc.mask as? CAShapeLayer)
            XCTAssertEqual(mask.lineWidth, 3)
            XCTAssertEqual(mask.lineCap, .round)
            XCTAssertNil(mask.fillColor)
            let path = try XCTUnwrap(mask.path)
            // A 3pt stroke leaves the same 2.2pt outer margin. Its centerline
            // radius is 18.3pt; each arc spans 80 degrees around top or bottom.
            XCTAssertEqual(path.boundingBoxOfPath.width, 2 * 18.3 * sin(.pi * 2 / 9), accuracy: 0.02)
            XCTAssertEqual(path.boundingBoxOfPath.height, 18.3 * (1 - cos(.pi * 2 / 9)), accuracy: 0.02)
            let colors = try XCTUnwrap(arc.colors as? [CGColor])
            XCTAssertEqual(colors.count, 3)
            XCTAssertEqual(try XCTUnwrap(colors.last).alpha, 1)
            XCTAssertEqual(try XCTUnwrap(colors.first).alpha, 0.25, accuracy: 0.0001)
            XCTAssertEqual(colors[1].alpha, 0.70, accuracy: 0.0001)
        }
        XCTAssertEqual(arcs[0].startPoint.x + arcs[1].startPoint.x, 1, accuracy: 0.0001)
        XCTAssertEqual(arcs[0].startPoint.y + arcs[1].startPoint.y, 1, accuracy: 0.0001)
        XCTAssertEqual(arcs[0].endPoint.x + arcs[1].endPoint.x, 1, accuracy: 0.0001)
        XCTAssertEqual(arcs[0].endPoint.y + arcs[1].endPoint.y, 1, accuracy: 0.0001)
        let before = arcs.map { ($0.mask as? CAShapeLayer)?.path }
        view.update(phase: .running, runningCount: 99, visible: false, hovered: true, dark: false, reduceMotion: false)
        for index in arcs.indices { XCTAssertEqual((arcs[index].mask as? CAShapeLayer)?.path, before[index]) }
    }

    @MainActor
    func testRefreshKeepsOneRotationAndResumingJoinsSharedPhase() throws {
        let (window, view) = hiddenFixture()
        defer { window.contentView = nil }
        let rotor = try layer("twinArc.rotor", in: view)
        view.update(phase: .running, runningCount: 1, visible: true, dark: true, reduceMotion: false)
        let first = try XCTUnwrap(rotor.animation(forKey: TwinArcOrbView.rotationKey) as? CABasicAnimation)
        XCTAssertEqual(first.duration, 3.2)
        XCTAssertEqual(first.keyPath, "transform.rotation.z")
        XCTAssertEqual((first.toValue as? NSNumber)?.doubleValue, .pi * 2)
        for (count, dark, hover) in [(2, true, false), (99, false, false), (100, false, true)] {
            view.update(phase: .running, runningCount: count, visible: true, hovered: hover, dark: dark, reduceMotion: false)
            view.layout()
            let refreshed = try XCTUnwrap(rotor.animation(forKey: TwinArcOrbView.rotationKey))
            XCTAssertEqual(refreshed.beginTime, first.beginTime)
            XCTAssertEqual(rotor.animationKeys(), [TwinArcOrbView.rotationKey])
            for name in ["twinArc.surface", "twinArc.center", "twinArc.alert"] {
                XCTAssertTrue(try layer(name, in: view).animationKeys()?.isEmpty ?? true)
            }
        }
        view.update(phase: .running, runningCount: 2, visible: false, dark: true, reduceMotion: false)
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        view.update(phase: .running, runningCount: 2, visible: true, dark: true, reduceMotion: false)
        XCTAssertEqual(rotor.animation(forKey: TwinArcOrbView.rotationKey)?.beginTime, first.beginTime)

        let (secondWindow, secondView) = hiddenFixture()
        defer { secondWindow.contentView = nil }
        secondView.update(phase: .running, runningCount: 1, visible: true, dark: true, reduceMotion: false)
        let secondRotor = try layer("twinArc.rotor", in: secondView)
        let second = try XCTUnwrap(secondRotor.animation(forKey: TwinArcOrbView.rotationKey))
        XCTAssertEqual(rotor.convertTime(first.beginTime, to: nil), secondRotor.convertTime(second.beginTime, to: nil), accuracy: 0.001)
        XCTAssertFalse(window.isActuallyVisible)
        XCTAssertFalse(secondWindow.isActuallyVisible)
    }

    @MainActor
    func testHiddenReducedMotionDetachedAndNonrunningViewsStopAnimation() throws {
        let (window, view) = hiddenFixture()
        defer { window.contentView = nil }
        let rotor = try layer("twinArc.rotor", in: view)
        func running(reduceMotion: Bool = false) {
            view.update(phase: .running, runningCount: 1, visible: true, dark: false, reduceMotion: reduceMotion)
        }
        running()
        XCTAssertNotNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        running(reduceMotion: true)
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        running()
        view.isHidden = true
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        view.isHidden = false
        XCTAssertNotNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        window.reportedVisible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        window.reportedVisible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertNotNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        window.reportedMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        window.reportedMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        XCTAssertNotNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        for phase in TaskPhase.allCases where phase != .running {
            view.update(phase: phase, runningCount: 3, visible: true, dark: true, reduceMotion: false)
            XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey), "\(phase) must be static, even with active conversations")
        }
        running()
        view.removeFromSuperview()
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        window.contentView = view
        running()
        XCTAssertNotNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        view.detach()
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertNil(rotor.animation(forKey: TwinArcOrbView.rotationKey))
    }

    @MainActor
    func testNative44PointRenderingHasOpaqueThemesReadableDigitsAndFadingArcs() throws {
        for dark in [true, false] {
            let view = TwinArcOrbView()
            view.update(phase: .running, runningCount: 1, visible: false, dark: dark, reduceMotion: false)
            let first = try render(view)
            XCTAssertEqual(first.pixelsWide, 44)
            XCTAssertEqual(first.pixelsHigh, 44)
            let background = try color(first, x: 5, y: 22)
            let expected = dark ? [23.0, 27.0, 33.0] : [252.0, 252.0, 253.0]
            for (actual, target) in zip([background.redComponent, background.greenComponent, background.blueComponent], expected) {
                XCTAssertEqual(actual, target / 255, accuracy: 0.012)
            }
            XCTAssertEqual(background.alphaComponent, 1)
            let centerPixels = try colors(first, in: NSRect(x: 15, y: 13, width: 14, height: 18))
            XCTAssertGreaterThan(centerPixels.filter { dark ? $0.redComponent > 0.8 : $0.redComponent < 0.25 }.count, 10,
                                 "The center number must actually render in the native 44-point bitmap")
            let ringPixels = try (0..<44).flatMap { y in
                try (0..<44).compactMap { x -> NSColor? in
                    let distance = hypot(Double(x) + 0.5 - 22, Double(y) + 0.5 - 22)
                    return distance > 17.5 && distance < 20.2 ? try color(first, x: x, y: y) : nil
                }
            }
            let bluePixels = ringPixels.filter { $0.blueComponent - $0.redComponent > 0.15 && $0.alphaComponent > 0.9 }
            XCTAssertGreaterThan(bluePixels.count, 20, "The native gradient/mask layers must actually render")
            XCTAssertLessThan(bluePixels.count, ringPixels.count / 2, "There must not be a complete colored progress track")
            XCTAssertGreaterThan(Set(bluePixels.map { Int($0.redComponent * 255) }).count, 8, "The arc tails must fade")

            view.update(phase: .running, runningCount: 100, visible: false, dark: dark, reduceMotion: true)
            let capped = try render(view)
            for y in 0..<44 {
                for x in 0..<44 where hypot(Double(x) + 0.5 - 22, Double(y) + 0.5 - 22) > 17.5 {
                    XCTAssertEqual(try rgba(first, x: x, y: y), try rgba(capped, x: x, y: y),
                                   "Running count must not turn the arcs into percentage progress")
                }
            }
        }
    }

    @MainActor
    func testAlertKeepsTheRunningNumberInTheSameRenderedPosition() throws {
        for dark in [true, false] {
            let view = TwinArcOrbView()
            view.update(phase: .running, runningCount: 3, visible: false, dark: dark, reduceMotion: false)
            let running = try render(view)
            for phase in [TaskPhase.waiting, .failed] {
                view.update(phase: phase, runningCount: 3, visible: false, dark: dark, reduceMotion: false)
                let notice = try render(view)
                for y in 11..<29 {
                    for x in 14..<30 {
                        XCTAssertEqual(try rgba(running, x: x, y: y), try rgba(notice, x: x, y: y),
                                       "An attention state must not move or paint over the running number")
                    }
                }
                let alert = try textLayer("twinArc.alert", in: view)
                XCTAssertEqual(alert.frame.midX, 22)
                XCTAssertEqual(alert.frame.minY, 28)
                XCTAssertTrue(alert.animationKeys()?.isEmpty ?? true)
            }
        }
    }

    @MainActor
    func testNativeCachingSnapshotIncludesTheOrb() throws {
        let (window, view) = hiddenFixture()
        defer { window.contentView = nil }
        view.update(phase: .waiting, runningCount: 12, visible: false, dark: false, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let sample = try color(bitmap, x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 5)
        XCTAssertGreaterThan(sample.alphaComponent, 0.9)
        if let directory = ProcessInfo.processInfo.environment["TWIN_ARC_RENDER_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-cache-waiting-12.png"))
        }
        XCTAssertFalse(window.isActuallyVisible)
    }

    @MainActor
    func testOffscreenStateAndThemeRendersRemainDistinct() throws {
        let exportDirectory = ProcessInfo.processInfo.environment["TWIN_ARC_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let exportDirectory { try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true) }
        for dark in [true, false] {
            var images = Set<Data>()
            for (name, phase, count) in [
                ("running-1", TaskPhase.running, 1), ("running-12", .running, 12),
                ("running-99plus", .running, 100), ("waiting", .waiting, 0),
                ("waiting-3", .waiting, 3), ("failed", .failed, 0),
                ("failed-3", .failed, 3), ("completed", .completed, 0),
                ("stopped", .stopped, 0), ("unknown", .unknown, 0), ("idle", .idle, 0)
            ] {
                let view = TwinArcOrbView()
                view.update(phase: phase, runningCount: count, visible: false, dark: dark, reduceMotion: false)
                let bitmap = try render(view)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertTrue(images.insert(data).inserted, "States must not collapse to one undifferentiated rendered image")
                if let exportDirectory {
                    let prefix = "\(dark ? "dark" : "light")-\(name)"
                    try data.write(to: exportDirectory.appendingPathComponent("\(prefix)-1x.png"))
                    try XCTUnwrap(render(view, scale: 4).representation(using: .png, properties: [:]))
                        .write(to: exportDirectory.appendingPathComponent("\(prefix)-4x.png"))
                }
            }
        }
    }

    @MainActor
    private func hiddenFixture() -> (TwinArcHiddenWindow, TwinArcOrbView) {
        _ = NSApplication.shared
        let window = TwinArcHiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
                                         styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TwinArcOrbView()
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    @MainActor
    private func layer(_ name: String, in view: TwinArcOrbView) throws -> CALayer {
        try XCTUnwrap(view.layer?.sublayers?.first { $0.name == name })
    }

    @MainActor
    private func textLayer(_ name: String, in view: TwinArcOrbView) throws -> CATextLayer {
        try XCTUnwrap(layer(name, in: view) as? CATextLayer)
    }

    @MainActor
    private func render(_ view: TwinArcOrbView, scale: Int = 1) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(view.layer)
        let context = try XCTUnwrap(CGContext(data: nil, width: 44 * scale, height: 44 * scale, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The native view/layer is y-down; a bitmap CGContext starts y-up.
        context.translateBy(x: 0, y: CGFloat(44 * scale))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        root.render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        return try XCTUnwrap(bitmap.retagging(with: .sRGB))
    }

    private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        // colorAt reports NSCalibratedRGB even for an sRGB-tagged bitmap; another
        // conversion then changes the channels a second time. Read these known
        // sRGB render bytes directly instead of treating them as calibrated RGB.
        XCTAssertEqual(bitmap.bitsPerSample, 8)
        XCTAssertEqual(bitmap.samplesPerPixel, 4)
        var pixel = [UInt](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: x, y: y)
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255)
    }

    private func rgba(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Int] {
        let color = try color(bitmap, x: x, y: y)
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    private func colors(_ bitmap: NSBitmapImageRep, in rect: NSRect) throws -> [NSColor] {
        try (Int(rect.minY)..<Int(rect.maxY)).flatMap { y in
            try (Int(rect.minX)..<Int(rect.maxX)).map { x in try color(bitmap, x: x, y: y) }
        }
    }
}

/// Exercises AppKit visibility callbacks without ever ordering a test window onto
/// the desktop. isActuallyVisible verifies that the real NSWindow stays hidden.
@MainActor
private final class TwinArcHiddenWindow: NSWindow {
    var reportedVisible = true
    var reportedMiniaturized = false
    override var isVisible: Bool { reportedVisible }
    override var isMiniaturized: Bool { reportedMiniaturized }
    var isActuallyVisible: Bool { super.isVisible }
}
