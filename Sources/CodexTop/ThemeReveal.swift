import AppKit
import QuartzCore
import CodexTopCore

private final class ThemeSnapshotView: NSView {
    let imageView = NSImageView()
    var image: NSImage? { get { imageView.image } set { imageView.image = newValue } }
    var glass = false
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(image: NSImage, light: Bool) {
        glass = light
        if light {
            let effect = GlassMaterial.makeBackdrop(frame: bounds)
            addSubview(effect)
        }
        imageView.frame = bounds; imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
    }
}

/// The live view switches once; a temporary, noninteractive image reveals it from the click.
@MainActor final class ThemeReveal {
    private weak var window: NSWindow?
    private var overlay: ThemeSnapshotView?
    private var mask: CAShapeLayer?
    private var origin = CGPoint.zero
    private var generation = 0
    private var removal: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func prepare(window: NSWindow, oldTheme: PanelTheme, pointInWindow: NSPoint?, cornerRadius: CGFloat) -> Bool {
        guard let content = window.contentView, content.bounds.width > 0, content.bounds.height > 0 else { cancel(); return false }
        content.layoutSubtreeIfNeeded()
        // Freeze the current presentation mask before replacing an in-flight reveal.
        let oldImage = self.window === window ? overlay?.image : nil
        let oldPath = self.window === window ? (mask?.presentation()?.path ?? mask?.path) : nil
        let oldOpacity = self.window === window ? (overlay?.layer?.presentation()?.opacity ?? overlay?.layer?.opacity ?? 1) : 1
        let oldGlass = self.window === window && overlay?.glass == true
        overlay?.isHidden = true
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { cancel(); return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let underlay = NSImage(size: content.bounds.size)
        underlay.addRepresentation(bitmap)
        let size = content.bounds.size
        // The overlay retains its own native glass. cacheDisplay cannot capture the
        // WindowServer backdrop; do not replace a normal light transition with a white card.
        let backing = oldTheme == .dark ? NSColor.black : NSColor.clear
        let image = NSImage(size: size, flipped: false) { bounds in
            backing.setFill(); bounds.fill()
            underlay.draw(in: bounds)
            if let oldImage, let oldPath, let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.addPath(oldPath); context.clip(using: .evenOdd)
                // Only an interrupted light reveal needs this approximation of its
                // previous backdrop; the normal path keeps live behind-window glass.
                if oldGlass { NSColor(calibratedWhite: 0.94, alpha: CGFloat(oldOpacity) * 0.9).setFill(); bounds.fill() }
                oldImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: CGFloat(oldOpacity))
                context.restoreGState()
            }
            return true
        }
        cancel()
        let view = ThemeSnapshotView(frame: content.bounds)
        view.configure(image: image, light: oldTheme == .light)
        view.setAccessibilityElement(false)
        view.wantsLayer = true
        view.layer?.contentsScale = window.backingScaleFactor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        content.addSubview(view, positioned: .above, relativeTo: nil)
        let point = pointInWindow.map { view.convert($0, from: nil) } ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        origin = view.bounds.contains(point) ? point : CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let mask = CAShapeLayer()
        mask.frame = view.bounds; mask.fillRule = .evenOdd; mask.fillColor = NSColor.black.cgColor
        mask.path = cutout(in: view.bounds, radius: 0.01)
        view.layer?.mask = mask
        self.window = window; overlay = view; self.mask = mask
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        return true
    }

    func reveal() {
        guard let overlay, let mask, let window else { return }
        let token = generation
        // Let SwiftUI commit its new, nonanimated colors before exposing the first pixels.
        removal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let duration = reduceMotion ? 0.10 : 0.42
            if reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0; fade.duration = duration
                overlay.layer?.opacity = 0
                overlay.layer?.add(fade, forKey: "themeFade")
            } else {
                let bounds = overlay.bounds
                let radius = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                              CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
                    .map { hypot($0.x - self.origin.x, $0.y - self.origin.y) }.max()! + 2
                let path = self.cutout(in: bounds, radius: radius)
                let reveal = CABasicAnimation(keyPath: "path")
                reveal.fromValue = mask.path; reveal.toValue = path; reveal.duration = duration
                reveal.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                mask.path = path
                CATransaction.commit()
                mask.add(reveal, forKey: "themeReveal")
            }
            try? await Task.sleep(for: .seconds(duration + 0.02))
            guard !Task.isCancelled, self.generation == token else { return }
            self.cancel()
        }
    }

    func cancel() {
        generation += 1
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        removal?.cancel(); removal = nil
        overlay?.removeFromSuperview(); overlay = nil
        mask = nil; window = nil
    }

    private func cutout(in bounds: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
}
