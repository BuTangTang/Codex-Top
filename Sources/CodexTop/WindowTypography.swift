import AppKit
import SwiftUI

private struct CompactMonitorTypographyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactMonitorTypography: Bool {
        get { self[CompactMonitorTypographyKey.self] }
        set { self[CompactMonitorTypographyKey.self] = newValue }
    }
}

extension View {
    /// Each hosting root follows its own native window, without sharing display
    /// preferences or replacing view identity as a window crosses screens.
    func windowTypography() -> some View { modifier(WindowTypographyModifier()) }
}

private struct WindowTypographyModifier: ViewModifier {
    @State private var compact = false

    func body(content: Content) -> some View {
        content
            .environment(\.compactMonitorTypography, compact)
            .background {
                WindowTypographyProbe { external in
                    guard compact != external else { return }
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { compact = external }
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct WindowTypographyProbe: NSViewRepresentable {
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> WindowTypographyProbeView {
        let view = WindowTypographyProbeView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: WindowTypographyProbeView, context: Context) {
        view.changed = changed
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: WindowTypographyProbeView, coordinator: ()) {
        view.stopObserving()
        view.changed = nil
    }
}

private final class WindowTypographyProbeView: NSView {
    var changed: ((Bool) -> Void)?
    private var updateScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                     NSWindow.didMoveNotification] {
            center.addObserver(self, selector: #selector(screenChanged), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(screenChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        scheduleUpdate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stopObserving() {
        // Selector registrations are also automatically removed on deallocation.
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenChanged(_ notification: Notification) { scheduleUpdate() }

    func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // SwiftUI can attach the native probe while updating its own hierarchy.
        // Coalesce notifications and publish outside that update transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let screen = self.window?.screen,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value != kCGNullDirectDisplay else { return }
            self.changed?(CGDisplayIsBuiltin(number.uint32Value) == 0)
        }
    }
}
