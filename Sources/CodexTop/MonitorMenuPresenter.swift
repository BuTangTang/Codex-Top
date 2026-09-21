import AppKit
import SwiftUI
import CodexTopCore

/// Keep the toolbar in the scaled panel, but place its menu in screen points.
/// A menu must not inherit the short panel's bounds or its text scaling.
@MainActor final class MonitorMenuPresenter: NSObject, ObservableObject {
    static let didOpen = Notification.Name("CodexTopMonitorMenuDidOpen")
    static let didClose = Notification.Name("CodexTopMonitorMenuDidClose")
    weak var anchor: NSView?
    @Published var focusedIndex: Int?
    private var actions: [() -> Void] = []
    private var panel: MonitorMenuPanel?
    private var menu: NSMenu?
    private var eventMonitors: [Any] = []
    private var windowObservers: [NSObjectProtocol] = []

    func present(store: TaskStore, compact: Bool, settings: @escaping () -> Void, collapse: (() -> Void)?) {
        if panel != nil { close(); return }
        guard let anchor, let window = anchor.window else { return }
        let menu = makeMenu(store: store, compact: compact, settings: settings, collapse: collapse)
        let buttonFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)) }
            ?? window.screen
        guard let screen else { return }
        let size = MonitorMenuContent.size(for: menu)
        let point = Self.popupOrigin(sourceFrame: window.frame, menuSize: size, visible: screen.visibleFrame)
        let panel = MonitorMenuPanel(contentRect: CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Top · 更多操作"
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = menu.appearance
        let content = NSHostingView(rootView: MonitorMenuContent(store: store, presenter: self, menu: menu))
        content.sizingOptions = []
        panel.contentView = content
        self.panel = panel; self.menu = menu; focusedIndex = nil
        // An independent utility surface keeps the opaque menu out of both the
        // scaled content tree and AppKit's translucent native-menu compositor.
        NotificationCenter.default.post(name: Self.didOpen, object: panel)
        installDismissal(for: panel, source: window, buttonFrame: buttonFrame)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil; menu = nil; focusedIndex = nil
        eventMonitors.forEach { NSEvent.removeMonitor($0) }; eventMonitors.removeAll()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers.removeAll()
        panel.orderOut(nil)
        actions.removeAll()
        NotificationCenter.default.post(name: Self.didClose, object: panel)
    }

    private func installDismissal(for panel: NSPanel, source: NSWindow, buttonFrame: CGRect) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self, weak panel, weak source] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.panel != nil else { return false }
                if event.type == .keyDown, self.handleKey(event.keyCode) { return true }
                if event.type != .keyDown && event.window !== panel {
                    if let source, event.window === source,
                       buttonFrame.contains(source.convertPoint(toScreen: event.locationInWindow)) {
                        // Consume the closing press so its release cannot reopen
                        // the menu, even after a cancelled drag or right click.
                        self.close()
                        return true
                    }
                    self.close()
                }
                return false
            }
            return consumed ? nil : event
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { eventMonitors.append(monitor) }
        for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: source, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }

    func handleKey(_ code: UInt16) -> Bool {
        guard let menu else { return false }
        if code == 53 { close(); return true }
        let selectable = menu.items.indices.filter { menu.items[$0].action != nil && menu.items[$0].isEnabled }
        guard !selectable.isEmpty else { return false }
        if code == 125 || code == 126 || code == 48 {
            let backwards = code == 126
            if let focusedIndex, let current = selectable.firstIndex(of: focusedIndex) {
                self.focusedIndex = selectable[(current + (backwards ? selectable.count - 1 : 1)) % selectable.count]
            } else { focusedIndex = backwards ? selectable.last : selectable.first }
            return true
        }
        if code == 36 || code == 76 {
            if let focusedIndex { performItem(at: focusedIndex) }
            return true
        }
        return false
    }

    func performItem(at index: Int) {
        guard let menu, menu.items.indices.contains(index) else { return }
        invoke(menu.items[index])
    }

    static func popupOrigin(sourceFrame: CGRect, menuSize: CGSize, visible: CGRect) -> CGPoint {
        let area = visible.insetBy(dx: 8, dy: 8)
        // Keep the monitor fully visible: open beside its right edge, or use
        // the left side when needed. Only the menu is clamped to the screen.
        let right = sourceFrame.maxX + 8, left = sourceFrame.minX - 8 - menuSize.width
        let proposedX = right + menuSize.width <= area.maxX ? right : left >= area.minX ? left : right
        let x = min(max(proposedX, area.minX), max(area.minX, area.maxX - menuSize.width))
        let y = min(area.maxY, max(sourceFrame.maxY, area.minY + menuSize.height))
        // NSPanel rounds fractional frame edges outward. Normalize the origin
        // so a scaled anchor cannot add a point to the menu's fixed dimensions.
        return CGPoint(x: floor(x + 1e-8), y: floor(y + 1e-8))
    }

    func makeMenu(store: TaskStore, compact: Bool, settings: @escaping () -> Void, collapse: (() -> Void)?) -> NSMenu {
        actions.removeAll()
        let menu = nativeMenu(theme: store.theme)
        menu.addItem(.sectionHeader(title: "显示方式"))
        for value in PanelPlacement.allCases {
            let entry = item(value.shortcutTitle, symbol: value.shortcutSymbol) {
                if store.placement != value { store.setPlacement(value) }
            }
            entry.state = store.placement == value ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "主题"))
        for (title, symbol, value) in [("深色", "moon", PanelTheme.dark), ("浅色", "sun.max", PanelTheme.light), ("跟随系统", "circle.lefthalf.filled", PanelTheme.system)] {
            let entry = item(title, symbol: symbol) { store.setTheme(value) }
            entry.state = store.themeChoice == value ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("监控设置…", symbol: "gearshape", action: settings))
        if compact {
            menu.addItem(.separator())
            menu.addItem(item("关闭浮窗", symbol: "xmark") { store.setFloating(false) })
        } else if store.placement != .orb, let collapse {
            menu.addItem(.separator())
            menu.addItem(item("收起面板", symbol: "chevron.down", action: collapse))
        }
        menu.update()
        return menu
    }

    private func nativeMenu(theme: PanelTheme) -> NSMenu {
        let menu = NSMenu()
        // Screen-coordinate menus cannot inherit the anchor window's appearance.
        menu.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        menu.font = .systemFont(ofSize: MonitorMenuContent.fontSize, weight: .medium)
        menu.minimumWidth = MonitorMenuContent.width
        return menu
    }

    private func item(_ title: String, symbol: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = self; item.tag = actions.count
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: MonitorMenuContent.fontSize, weight: .regular))
        actions.append(action)
        return item
    }

    @objc private func invoke(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        let action = actions[item.tag]
        close()
        action()
    }
}

struct MonitorMenuAnchor: NSViewRepresentable {
    let presenter: MonitorMenuPresenter
    func makeNSView(context: Context) -> MenuAnchorView {
        let view = MenuAnchorView()
        view.setAccessibilityElement(false)
        presenter.anchor = view
        return view
    }
    func updateNSView(_ view: MenuAnchorView, context: Context) {}
}

final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
