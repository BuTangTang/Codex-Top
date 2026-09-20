import AppKit

/// Fade the old surface out before replacing it. Only one monitor surface is
/// visible at a time, and a superseded transition cannot reopen an old mode.
@MainActor final class PanelModeTransition {
    private var task: Task<Void, Never>?
    private var generation = 0
    private var windows: [NSWindow] = []
    private var mouseEvents: [Bool] = []
    private var pendingUpdate: (() -> Void)?
    private var completion: (() -> Void)?
    var isActive: Bool { task != nil }

    func run(windows: [NSWindow], animated: Bool, update: @escaping () -> Void,
             completion: @escaping () -> Void = {}) {
        cancel()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            update(); completion(); return
        }
        self.windows = windows
        mouseEvents = windows.map(\.ignoresMouseEvents)
        pendingUpdate = update; self.completion = completion
        windows.forEach { $0.ignoresMouseEvents = true }
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            windows.filter(\.isVisible).forEach { $0.animator().alphaValue = 0 }
        }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(110)) } catch { return }
            guard let self, self.generation == token else { return }
            // The content branch and geometry change only while both windows
            // are hidden; the next surface starts at its final size and scale.
            windows.forEach { $0.orderOut(nil); $0.alphaValue = 0 }
            self.pendingUpdate = nil
            update()
            windows.filter(\.isVisible).forEach {
                $0.contentView?.layoutSubtreeIfNeeded()
                $0.displayIfNeeded()
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                windows.filter(\.isVisible).forEach { $0.animator().alphaValue = 1 }
            }, completionHandler: nil)
            do { try await Task.sleep(for: .milliseconds(170)) } catch { return }
            guard self.generation == token else { return }
            self.task = nil
            self.restoreWindows()
            self.completion = nil
            completion()
        }
    }

    /// Display changes can settle the requested mode immediately before recovery.
    func finish() {
        let update = pendingUpdate, done = completion
        cancel()
        update?(); done?()
    }

    private func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        pendingUpdate = nil; completion = nil
        restoreWindows()
    }

    private func restoreWindows() {
        for (window, ignoresEvents) in zip(windows, mouseEvents) {
            window.alphaValue = 1
            window.ignoresMouseEvents = ignoresEvents
        }
        windows = []; mouseEvents = []
    }
}
