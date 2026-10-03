import AppKit
import GoalEditWorkflow

/// 仅操作本测试窗口的控件和内存数据；没有真实应用、网络或文件读写入口。
@MainActor
final class FixtureAdapter: GoalEditAdapter {
    var identity = GoalIdentity(account: "fixture-account", sourceMachine: "fixture-mac", thread: "fixture-thread", connection: "fixture-connection")
    var fact: GoalFact = .available(FixtureAdapter.initialGoal)
    var scenario = 0
    var actionCount = 0
    var applyText: ((String) -> Void)?
    var pressSave: (() -> Void)?
    var pressDelete: (() -> Void)?

    static var initialGoal: GoalSnapshot {
        GoalSnapshot(content: GoalContent(objective: "完善手机目标编辑体验", status: .paused, tokenBudget: nil), tokensUsed: 100, timeUsedSeconds: 30, updatedAt: 1)
    }

    /// 返回测试窗口自己的内存目标；用例可模拟动作后读取中断。
    func readGoal() async throws -> GoalFact {
        if scenario == 1 && actionCount > 0 { throw FixtureError.receiptLost }
        return fact
    }

    /// 先核对测试目标，再填入本窗口编辑框并点击本窗口保存按钮。
    func replaceObjective(_ objective: String, preserving expected: GoalContent) async throws {
        guard case let .available(snapshot) = fact, snapshot.content == expected else { throw FixtureError.changed }
        actionCount += 1
        if scenario == 2 { return }
        applyText?(objective)
        pressSave?()
        if scenario == 1 { throw FixtureError.receiptLost }
    }

    /// 删除仅指本窗口的可重建合成目标，保留整个测试会话。
    func deleteGoal(expected: GoalContent) async throws {
        guard case let .available(snapshot) = fact, snapshot.content == expected else { throw FixtureError.changed }
        actionCount += 1
        if scenario == 2 { return }
        pressDelete?()
        if scenario == 1 { throw FixtureError.receiptLost }
    }

    enum FixtureError: Error { case receiptLost, changed }
}

/// 展示一次编辑会话及模拟桌面控件，供人工和 CUA 核验控件状态。
@MainActor
final class FixtureController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let adapter = FixtureAdapter()
    private var session: GoalEditSession!
    private let mobileInput = NSTextField(string: "")
    private let desktopInput = NSTextField(string: "")
    private let desktopGoal = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let scenario = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var desktopSave = NSButton(title: "保存模拟桌面目标", target: self, action: #selector(saveDesktopGoal))
    private lazy var desktopDelete = NSButton(title: "删除模拟桌面目标", target: self, action: #selector(deleteDesktopGoal))

    /// 创建明确标为合成数据的独立窗口，不激活或读取正式产品。
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出目标操作验证", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 820, height: 540), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "目标操作验证 · 仅合成数据"
        window.isReleasedWhenClosed = false
        let root = stack(.vertical, spacing: 18)
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.addArrangedSubview(label("目标操作独立验证", size: 23, bold: true))
        root.addArrangedSubview(label("未连接 Codex 或手机。所有目标都在本窗口内存中，重置即可恢复。", size: 13))

        scenario.addItems(withTitles: ["正常操作", "动作成功但回执丢失", "动作返回但内容未变"])
        scenario.target = self
        scenario.action = #selector(changeScenario)
        scenario.setAccessibilityLabel("测试场景")
        let toolbar = stack(.horizontal, spacing: 12)
        toolbar.addArrangedSubview(scenario)
        toolbar.addArrangedSubview(button("重置样例", #selector(resetFixture)))
        toolbar.addArrangedSubview(button("模拟桌面先修改", #selector(simulateConcurrentEdit)))
        root.addArrangedSubview(toolbar)

        let columns = stack(.horizontal, spacing: 24)
        columns.distribution = .fillEqually
        let mobile = stack(.vertical, spacing: 12)
        mobile.addArrangedSubview(label("手机侧操作（模拟）", size: 17, bold: true))
        mobileInput.placeholderString = "目标正文"
        mobileInput.setAccessibilityLabel("手机目标正文")
        mobile.addArrangedSubview(mobileInput)
        let actions = stack(.horizontal, spacing: 10)
        actions.addArrangedSubview(button("提交修改", #selector(submitReplacement)))
        actions.addArrangedSubview(button("删除目标", #selector(submitDeletion)))
        mobile.addArrangedSubview(actions)
        mobile.addArrangedSubview(button("仅重新核对结果", #selector(recheckResult)))
        resultLabel.setAccessibilityLabel("操作结果")
        mobile.addArrangedSubview(resultLabel)
        mobile.addArrangedSubview(countLabel)

        let desktop = stack(.vertical, spacing: 12)
        desktop.addArrangedSubview(label("桌面目标（模拟）", size: 17, bold: true))
        desktopGoal.setAccessibilityLabel("桌面权威目标")
        desktop.addArrangedSubview(desktopGoal)
        desktopInput.setAccessibilityLabel("模拟桌面目标编辑框")
        desktop.addArrangedSubview(desktopInput)
        desktop.addArrangedSubview(desktopSave)
        desktop.addArrangedSubview(desktopDelete)
        columns.addArrangedSubview(mobile)
        columns.addArrangedSubview(desktop)
        root.addArrangedSubview(columns)
        root.addArrangedSubview(label("验证点：目标一致才执行；同一操作不重复派发；结果未知时只回读。\n本实验不证明真实 Codex 的编辑入口、权限和并发控制已可用。", size: 12))

        let content = NSView()
        window.contentView = content
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        adapter.applyText = { [weak self] in self?.desktopInput.stringValue = $0 }
        adapter.pressSave = { [weak self] in self?.desktopSave.performClick(nil) }
        adapter.pressDelete = { [weak self] in self?.desktopDelete.performClick(nil) }
        resetFixture()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 关闭窗口同时结束独立样例，避免残留测试进程。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 构造垂直或水平排列；控件保持原生键盘与辅助功能行为。
    private func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat) -> NSStackView {
        let result = NSStackView()
        result.orientation = orientation
        result.alignment = orientation == .vertical ? .leading : .top
        result.spacing = spacing
        return result
    }

    /// 生成可换行的说明，不包含任何真实目标内容。
    private func label(_ text: String, size: CGFloat, bold: Bool = false) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return result
    }

    /// 将按钮绑定到本窗口的显式测试动作。
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }

    /// 恢复合成目标，并新建一次性编辑会话；不读取磁盘或真实来源。
    @objc private func resetFixture() {
        adapter.fact = .available(FixtureAdapter.initialGoal)
        adapter.actionCount = 0
        adapter.scenario = scenario.indexOfSelectedItem
        session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        mobileInput.stringValue = "改进手机目标编辑和删除体验"
        desktopInput.stringValue = FixtureAdapter.initialGoal.content.objective
        resultLabel.stringValue = "尚未提交"
        refreshDesktop()
    }

    /// 切换故障注入场景不隐式重置或重发，便于观察回执恢复。
    @objc private func changeScenario() { adapter.scenario = scenario.indexOfSelectedItem }

    /// 模拟电脑端在手机开始编辑后修改原目标，预检应阻止旧稿覆盖。
    @objc private func simulateConcurrentEdit() {
        desktopInput.stringValue = "电脑端已经更新的目标"
        saveDesktopGoal()
    }

    /// 保存本窗口编辑控件内容，保留合成目标状态、预算及已用量。
    @objc private func saveDesktopGoal() {
        guard case let .available(snapshot) = adapter.fact else { return }
        adapter.fact = .available(GoalSnapshot(content: GoalContent(objective: desktopInput.stringValue, status: snapshot.content.status, tokenBudget: snapshot.content.tokenBudget), tokensUsed: snapshot.tokensUsed, timeUsedSeconds: snapshot.timeUsedSeconds, updatedAt: (snapshot.updatedAt ?? 0) + 1))
        refreshDesktop()
    }

    /// 清除合成目标，重置样例可随时恢复，不删除会话或文件。
    @objc private func deleteDesktopGoal() {
        adapter.fact = .none
        refreshDesktop()
    }

    /// 固定当前一次编辑会话，避免样例重置后旧回调污染新窗口状态。
    @objc private func submitReplacement() {
        let current = session!
        let objective = mobileInput.stringValue
        Task { @MainActor in
            let result = await current.replaceObjective(objective, expectedStatus: .paused)
            guard self.session === current else { return }
            show(result)
        }
    }

    /// 发起一次明确删除，重复点击继续使用同一会话而不重投。
    @objc private func submitDeletion() {
        let current = session!
        Task { @MainActor in
            let result = await current.delete()
            guard self.session === current else { return }
            show(result)
        }
    }

    /// 回执丢失后仅检查真实的合成目标，不再次点击保存或删除。
    @objc private func recheckResult() {
        let current = session!
        Task { @MainActor in
            let result = await current.recheck()
            guard self.session === current else { return }
            show(result)
        }
    }

    /// 把操作结果与目标运行状态分开呈现，避免“调用返回”冒充成功。
    private func show(_ result: GoalOperationResult) {
        switch result {
        case .verified: resultLabel.stringValue = "回读已确认：已观察到预期目标状态"
        case .unknown: resultLabel.stringValue = "结果未知：未重复执行，可仅重新核对结果"
        case .conflict: resultLabel.stringValue = "原目标已变化：本次未执行"
        case let .notPerformed(reason): resultLabel.stringValue = "未执行：\(reason.description)"
        }
        refreshDesktop()
    }

    /// 渲染内存来源及动作计数；动作次数与界面点击次数分开。
    private func refreshDesktop() {
        switch adapter.fact {
        case let .available(snapshot): desktopGoal.stringValue = "\(snapshot.content.objective)\n状态：\(snapshot.content.status.rawValue)\n预算：\(snapshot.content.tokenBudget.map(String.init) ?? "未知")\n已用 Token：\(snapshot.tokensUsed.map(String.init) ?? "未知")"
        case .none: desktopGoal.stringValue = "明确没有目标（none）"
        case .unknown: desktopGoal.stringValue = "目标未知（unknown）"
        }
        countLabel.stringValue = "实际派发次数：\(adapter.actionCount)"
    }
}

let application = NSApplication.shared
let controller = FixtureController()
application.delegate = controller
application.run()
