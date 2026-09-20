import AppKit
import SwiftUI

/// Keep hit testing in the view, then hand window movement to Window Server.
struct WindowDragHandle: NSViewRepresentable {
    var started: (CGPoint) -> Void
    var moved: (CGPoint) -> Void
    var ended: (CGPoint) -> Void
    var excludedFrames: [CGRect] = []
    var enabled = true

    func makeNSView(context: Context) -> NativeWindowDragView {
        let view = NativeWindowDragView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NativeWindowDragView, context: Context) {
        view.started = started
        view.moved = moved
        view.ended = ended
        view.excludedFrames = excludedFrames
        view.enabled = enabled
    }
}

final class NativeWindowDragView: NSView {
    var started: (CGPoint) -> Void = { _ in }
    var moved: (CGPoint) -> Void = { _ in }
    var ended: (CGPoint) -> Void = { _ in }
    var excludedFrames: [CGRect] = []
    var enabled = true
    private var tracking = false
    private var nativeDragging = false
    private var releaseTimer: Timer?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard enabled, !isHidden, bounds.contains(local),
              !excludedFrames.contains(where: { $0.contains(local) }) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        tracking = true
        started(desktopPoint(for: event))
        if let window {
            nativeDragging = true
            // This returns immediately and AppKit may consume mouseUp. Observe
            // button release in common modes instead of assuming delivery to us.
            window.performDrag(with: event)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.tracking else { return }
                    let point = NSEvent.mouseLocation
                    self.moved(point)
                    if NSEvent.pressedMouseButtons & 1 == 0 { self.finishTracking(at: point) }
                }
            }
            releaseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        guard !nativeDragging else { return }
        moved(desktopPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        let point = desktopPoint(for: event)
        moved(point)
        finishTracking(at: point)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishTracking(at: NSEvent.mouseLocation) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finishTracking(at point: CGPoint) {
        guard tracking else { return }
        tracking = false
        nativeDragging = false
        releaseTimer?.invalidate()
        releaseTimer = nil
        ended(point)
    }

    private func desktopPoint(for event: NSEvent) -> CGPoint {
        // This event owns the desktop point; neither the window's new origin nor
        // NSApp.currentEvent (which SwiftUI may replace) participates in the drag.
        event.cgEvent?.unflippedLocation ?? NSEvent.mouseLocation
    }
}
