import AppKit
import SwiftUI

@MainActor final class FloatingResizeState: ObservableObject {
    @Published var size: CGSize = .zero
}

/// Interpolate the viewport, without applying a second animation to its text.
/// The native window remains a fixed canvas until the resize has completed.
struct FloatingViewport: AnimatableModifier {
    var size: CGSize
    let scale: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    func body(content: Content) -> some View {
        GeometryReader { _ in
            content
                .frame(width: max(1, size.width) / max(0.1, scale),
                       height: max(1, size.height) / max(0.1, scale), alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: max(1, size.width), height: max(1, size.height), alignment: .topLeading)
                .transaction { $0.animation = nil }
        }
    }
}

@MainActor final class FloatingPanelResize {
    private weak var window: NSWindow?
    private let state: FloatingResizeState
    private let reduceMotion: @MainActor () -> Bool
    private var completion: Task<Void, Never>?
    private var generation = 0
    private var target: CGRect?
    private var pending: (frame: CGRect, animated: Bool)?
    private var savedShadow: Bool?
    private(set) var isAnimating = false
    private(set) var isPositioning = false

    init(window: NSWindow, state: FloatingResizeState,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.window = window
        self.state = state
        self.reduceMotion = reduceMotion
    }

    /// Match AppKit's integral point frames before comparing or animating them.
    static func integralTarget(_ frame: CGRect) -> CGRect {
        let epsilon: CGFloat = 1e-8
        let x = floor(frame.minX + epsilon), y = floor(frame.minY + epsilon)
        return CGRect(x: x, y: y, width: max(1, ceil(frame.maxX - epsilon) - x),
                      height: max(1, ceil(frame.maxY - epsilon) - y))
    }

    /// Preserve the top-left opening edge. When there is no room underneath,
    /// shorten the scrolling viewport instead of moving every visible row up.
    static func targetFrame(from frame: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let epsilon: CGFloat = 1e-8
        let area = visible.insetBy(dx: 8, dy: 8)
        // Use integral edges inside the screen so AppKit's outward rounding
        // cannot push a fractional display boundary outside the usable area.
        let left = ceil(area.minX - epsilon), bottom = ceil(area.minY - epsilon)
        let right = max(left + 1, floor(area.maxX + epsilon))
        let ceiling = max(bottom + 1, floor(area.maxY + epsilon))
        let top = min(max(floor(frame.maxY + epsilon), bottom + 1), ceiling)
        let width = min(max(1, ceil(size.width - epsilon)), right - left)
        let height = min(max(1, ceil(size.height - epsilon)), top - bottom)
        let x = min(max(floor(frame.minX + epsilon), left), right - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    func resize(to requested: CGRect, animated: Bool) {
        guard let window else { return }
        let next = Self.integralTarget(requested)
        if isAnimating {
            // Only the most recent request matters. Never restart from a model
            // size that is already the animation endpoint rather than its frame.
            pending = next == target ? nil : (next, animated)
            return
        }
        let from = window.frame
        guard next != from else {
            // A newly attached SwiftUI view can need its initial size even when
            // AppKit already has the destination. This is not a resize animation.
            if state.size != next.size { commit(next) }
            return
        }
        target = next
        let stableAnchor = from.minX == next.minX && from.maxY == next.maxY
        guard animated, stableAnchor, from.width > 0, from.height > 0,
              !reduceMotion() else {
            commit(next)
            target = nil
            return
        }
        generation += 1
        let token = generation
        isAnimating = true
        savedShadow = window.hasShadow
        window.hasShadow = false
        atomicLayout {
            self.state.size = from.size
            let canvas = from.union(next)
            if window.frame != canvas { window.setFrame(canvas, display: false) }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        withAnimation(.easeInOut(duration: 0.20)) { state.size = next.size }
        completion = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard let self, self.generation == token else { return }
            self.completion = nil
            self.isAnimating = false
            self.commit(next)
            self.target = nil
            self.restoreShadow()
            let queued = self.pending
            self.pending = nil
            if let queued { self.resize(to: queued.frame, animated: queued.animated) }
        }
    }

    /// Resolve the most recent requested size before a native drag begins.
    func finish() { stop(commitPending: true) }

    /// Discard queued work before the same window changes display mode.
    func cancel() { stop(commitPending: false) }

    private func stop(commitPending: Bool) {
        generation += 1
        completion?.cancel(); completion = nil
        let final = commitPending ? pending?.frame ?? target : target
        pending = nil
        isAnimating = false
        if let final { commit(final) }
        target = nil
        restoreShadow()
    }

    private func commit(_ frame: CGRect) {
        guard let window else { return }
        atomicLayout {
            self.state.size = frame.size
            if window.frame != frame { window.setFrame(frame, display: false) }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
    }

    private func atomicLayout(_ action: () -> Void) {
        let previous = isPositioning
        isPositioning = true
        defer { isPositioning = previous }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction, action)
        }
    }

    private func restoreShadow() {
        guard let savedShadow else { return }
        window?.hasShadow = savedShadow
        window?.invalidateShadow()
        self.savedShadow = nil
    }
}
