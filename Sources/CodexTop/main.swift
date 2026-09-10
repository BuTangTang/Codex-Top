import AppKit
import Combine
import CodexTopCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TaskStore!
    private var windows: WindowController!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusObservation: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        store = TaskStore(); windows = WindowController(store: store)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Codex Top")
        statusItem.button?.toolTip = "Codex Top · 任务监控"
        let menu = NSMenu()
        add("显示任务", #selector(showTasks), to: menu)
        add("选择任务…", #selector(pickTasks), to: menu)
        add("悬浮 / 收回顶部", #selector(toggleFloating), to: menu)
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
        NSApp.mainMenu = main
        statusObservation = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        updateStatusItem()
        store.start()
        if CommandLine.arguments.contains("--show") { windows.toggleExpanded() }
    }
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.cornerRadius = 0
        if store.placement == .menuBar {
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            let text = "  ● \(store.runningCount)   ● \(store.attentionCount)  "
            let title = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
            let string = text as NSString
            title.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: string.range(of: "●"))
            title.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: string.range(of: "●", options: .backwards))
            button.attributedTitle = title
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.title = ""
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Codex Top")
        }
        button.toolTip = "Codex Top · \(store.runningCount) 个运行中 · \(store.attentionCount) 个待处理"
        button.setAccessibilityLabel(button.toolTip)
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
            statusItem.menu = statusMenu
            defer { statusItem.menu = nil }
            sender.performClick(nil)
        } else {
            showTasks()
        }
    }
    @objc private func showTasks() {
        if store.placement == .menuBar {
            let anchor = statusItem.button.flatMap { button in
                button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
            }
            windows.toggleStatusPanel(anchor: anchor)
        }
        else { windows.toggleExpanded() }
    }
    @objc private func pickTasks() { windows.showPicker() }
    @objc private func toggleFloating() { store.setFloating(!store.preferences.floating) }
    @objc private func showOrb() { store.setPlacement(.orb) }
    @objc private func menuBarOnly() { store.setPlacement(.menuBar) }
    @objc private func recover() { windows.recoverWindows() }
    @objc private func settings() { windows.showSettings() }
    @objc private func refresh() { store.refreshQuota(force: true); Task { await store.refresh() } }
    @objc private func usage() { store.openUsagePage() }
    @objc private func quit() { store.stop(); NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
