import AppKit
import Combine
import CodexTopCore

/// 状态栏实际展示所依赖的值，外观变化也必须允许重新应用动态颜色。
struct StatusItemPresentation: Equatable {
    let placement: PanelPlacement
    let running: Int
    let attention: Int
    let theme: PanelTheme
    let appearance: NSAppearance.Name
}

/// 只负责单个状态栏按钮的展示，不持有任务仓库、窗口或异步回调。
@MainActor struct StatusItemRenderer {
    private var lastPresentation: StatusItemPresentation?

    /// 同一入口负责长度、文案、图标和读屏信息，便于核验真实 AppKit 写入边界。
    mutating func update(_ presentation: StatusItemPresentation, button: NSButton, setLength: (CGFloat) -> Void) {
        // 只记住此按钮已应用的展示；任务、偏好或系统外观变化时仍立即应用新值。
        guard lastPresentation != presentation else { return }
        if presentation.placement == .menuBar {
            setLength(NSStatusItem.variableLength)
            button.image = nil
            let text = "  ● \(presentation.running)   ● \(presentation.attention)  "
            let title = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
            let string = text as NSString
            title.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: string.range(of: "●"))
            title.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: string.range(of: "●", options: .backwards))
            button.attributedTitle = title
        } else {
            setLength(NSStatusItem.squareLength)
            button.title = ""
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Codex Top")
        }
        button.toolTip = "Codex Top · \(presentation.running) 个运行中 · \(presentation.attention) 个待处理"
        button.setAccessibilityLabel(button.toolTip)
        lastPresentation = presentation
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TaskStore!
    private var windows: WindowController!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusObservation: AnyCancellable?
    private var statusRenderer = StatusItemRenderer()
    private var shutdownTask: Task<Void, Never>?
    /// 启动唯一状态栏入口并应用固定样式，再接入任务展示更新与窗口操作。
    func applicationDidFinishLaunching(_ notification: Notification) {
        store = TaskStore(); windows = WindowController(store: store)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.wantsLayer = true
        statusItem.button?.layer?.backgroundColor = NSColor.clear.cgColor
        statusItem.button?.layer?.cornerRadius = 0
        windows.statusAnchorProvider = { [weak self] in
            guard let button = self?.statusItem?.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Codex Top")
        statusItem.button?.toolTip = "Codex Top · 任务监控"
        let menu = NSMenu()
        add("显示任务", #selector(showTasks), to: menu)
        add("选择任务…", #selector(pickTasks), to: menu)
        add("切换常驻浮窗", #selector(toggleFloating), to: menu)
        add("圆环模式", #selector(showOrb), to: menu)
        add("仅状态栏", #selector(menuBarOnly), to: menu)
        add("找回窗口", #selector(recover), to: menu)
        menu.addItem(.separator())
        add("设置…", #selector(settings), to: menu, key: ",")
        add("立即刷新", #selector(refresh), to: menu)
        add("Codex 用量页面…", #selector(usage), to: menu)
        menu.addItem(.separator())
        add("退出 Codex Top", #selector(quit), to: menu, key: "q")
        statusMenu = menu
        windows.orbContextMenu = menu
        // Keep the menu detached so a normal click reaches the task panel directly.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let main = NSMenu(); let applicationItem = NSMenuItem(); main.addItem(applicationItem)
        let appMenu = NSMenu(); applicationItem.submenu = appMenu
        add("显示任务", #selector(showTasks), to: appMenu, key: "t")
        add("设置…", #selector(settings), to: appMenu, key: ",")
        add("找回窗口", #selector(recover), to: appMenu)
        appMenu.addItem(.separator())
        add("退出 Codex Top", #selector(quit), to: appMenu, key: "q")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "编辑"); editItem.submenu = edit; main.addItem(editItem)
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "显示"); viewItem.submenu = viewMenu; main.addItem(viewItem)
        add("放大", #selector(increaseScale), to: viewMenu, key: "+")
        add("缩小", #selector(decreaseScale), to: viewMenu, key: "-")
        // App-menu equivalents stay local to the active app; '=' also works without Shift.
        let increaseAlias = NSMenuItem(title: "放大", action: #selector(increaseScale), keyEquivalent: "=")
        increaseAlias.target = self; increaseAlias.isHidden = true
        increaseAlias.allowsKeyEquivalentWhenHidden = true; viewMenu.addItem(increaseAlias)
        NSApp.mainMenu = main
        statusObservation = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        updateStatusItem()
        store.start()
        if CommandLine.arguments.contains("--show") { windows.toggleExpanded() }
    }
    /// 广播后读取一次当前汇总，保留原队列和生命周期，不改变任务刷新频率。
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let summary = store.statusSummary
        let presentation = StatusItemPresentation(placement: store.placement, running: summary.running,
                                                  attention: summary.attention, theme: store.theme,
                                                  appearance: button.effectiveAppearance.name)
        statusRenderer.update(presentation, button: button) { statusItem.length = $0 }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if shutdownTask == nil {
            store.stop()
            shutdownTask = Task {
                await store.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { store?.stop() }
    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // A temporary menu owns its native tracking loop, including keyboard navigation.
        guard statusItem.menu == nil else { return }
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isContextClick {
            statusMenu.appearance = NSAppearance(named: store.theme == .light ? .aqua : .darkAqua)
            statusItem.menu = statusMenu
            defer { statusItem.menu = nil }
            sender.performClick(nil)
        } else {
            showTasks()
        }
    }
    @objc private func showTasks() {
        if store.placement == .menuBar {
            windows.toggleStatusPanel()
        }
        else { windows.toggleExpanded() }
    }
    @objc private func pickTasks() { windows.showPicker() }
    @objc private func toggleFloating() { store.setFloating(!store.preferences.floating) }
    @objc private func showOrb() { store.setPlacement(.orb) }
    @objc private func menuBarOnly() { store.setPlacement(.menuBar) }
    @objc private func recover() { windows.recoverWindows() }
    @objc private func settings() { windows.showSettings() }
    @objc private func increaseScale() { store.setScale(store.preferences.resolvedDisplayScale + MonitorScale.step) }
    @objc private func decreaseScale() { store.setScale(store.preferences.resolvedDisplayScale - MonitorScale.step) }
    @objc private func refresh() { store.refreshQuota(force: true); Task { await store.refresh() } }
    @objc private func usage() { store.openUsagePage() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
