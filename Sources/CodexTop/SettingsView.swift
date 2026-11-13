import SwiftUI
import ServiceManagement
import CodexTopCore

/// 设置窗口（2026-11-12 按设计 B 改版）：和悬浮球、面板同一种近黑 LED 风格，界面上不放小字（说明在悬停提示里），
/// 侧栏六页：显示、任务、用量、设备、手机连接、数据与启动。各项设置的绑定和行为不变。
struct SettingsView: View {
    /// 显示器变化通过独立状态更新，不重建设置视图或持久化页面中的输入。
    @MainActor final class DisplayState: ObservableObject {
        @Published var choices: [DisplayChoice] = []
        /// 由设置窗口持有；首次窗口布局会填入当前可用显示器。
        init() {}
    }

    private enum Category: String, CaseIterable, Identifiable {
        case appearance, tasks, usage, device, mobile, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: "显示"
            case .tasks: "任务"
            case .usage: "用量"
            case .device: "设备"
            case .mobile: "手机连接"
            case .system: "数据与启动"
            }
        }
    }

    @ObservedObject var store: TaskStore
    @ObservedObject var mobileAccount: MobileAccountStore
    @ObservedObject var displayState: DisplayState
    @ObservedObject private var deviceAccess = DeviceAccessMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var recoverWindows: () -> Void
    // 分类仅属于当前设置窗口，不新增持久化偏好或影响监控列表。
    @State private var selectedCategory: Category = .appearance
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var confirmClaudeHook = false

    private var scheme: ColorScheme { store.theme.colorScheme }
    private var secondary: Color { Palette.secondary(scheme) }
    private var warning: Color { Color(nsColor: LEDOrbView.toneColor(.waiting, dark: scheme == .dark)) }

    /// 演示环境不展示真实账号连接入口，也不开设备接口。
    private var categories: [Category] {
        Category.allCases.filter { !store.demo || ($0 != .mobile && $0 != .device) }
    }

    /// 回读系统登录项授权结果，不在切换分类时重复注册登录项。
    private func refreshLoginStatus() {
        let current: SMAppService.Status = store.demo ? .notRegistered : SMAppService.mainApp.status
        if current != loginStatus { loginError = nil }
        loginStatus = current
    }

    /// 继续使用原有系统登录项入口，并保留失败后的说明与状态回读。
    private func setLoginEnabled(_ enabled: Bool) {
        guard !store.demo else { return }
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "无法修改登录项。请将应用放入 Applications 后重试。"
        }
        refreshLoginStatus()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.hairline(scheme)).frame(width: 1)
            Group {
                if selectedCategory == .mobile {
                    // 手机连接功能不动，沿用原来的表单，只换底色和标题。
                    VStack(alignment: .leading, spacing: 0) {
                        pageTitle.padding(.horizontal, 24).padding(.top, 20)
                        Form { MobileAccountSection(account: mobileAccount) }
                            .formStyle(.grouped).scrollContentBackground(.hidden)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            pageTitle
                            page
                        }
                        .padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .id(selectedCategory)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selectedCategory)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("settings-detail-\(selectedCategory.rawValue)")
        }
        .background(LEDOrbView.panelColor(dark: scheme == .dark))
        .foregroundStyle(Palette.primary(scheme))
        .tint(Palette.accent)
        .buttonStyle(SettingsButtonStyle())
        .environment(\.colorScheme, scheme)
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginStatus() }
    }

    private var pageTitle: some View {
        Text(selectedCategory.title).font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader).padding(.bottom, 4)
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                // 32pt 正好是图标里自带的一档（1 倍屏 32 像素、2 倍屏 64 像素），不用缩放，不发糊。
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 32, height: 32).accessibilityHidden(true)
                Text("Codex Top").font(.system(size: 14, weight: .bold))
            }
            .padding(.horizontal, 6).padding(.top, 18).padding(.bottom, 16)
            ForEach(categories) { category in
                let on = category == selectedCategory
                Button { selectedCategory = category } label: {
                    HStack(spacing: 10) {
                        SettingsPip(on: on)
                        Text(category.title).font(.system(size: 13.5, weight: on ? .semibold : .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? Palette.primary(scheme) : secondary)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(on ? Palette.primary(scheme).opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("settings-category-\(category.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        // 方向键上下切换分类，代替原来系统列表的键盘选择。
        .onMoveCommand { direction in
            guard let index = categories.firstIndex(of: selectedCategory) else { return }
            switch direction {
            case .up where index > 0: selectedCategory = categories[index - 1]
            case .down where index < categories.count - 1: selectedCategory = categories[index + 1]
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置分类")
    }

    @ViewBuilder private var page: some View {
        switch selectedCategory {
        case .appearance: appearancePage
        case .tasks: tasksPage
        case .usage: usagePage
        case .device: devicePage
        case .mobile: EmptyView()
        case .system: systemPage
        }
    }

    // MARK: 显示

    @ViewBuilder private var appearancePage: some View {
        // 实时预览：真实的悬浮球点阵和面板缩略图，跟着配色走。
        HStack(spacing: 16) {
            LEDOrbContent(store: store, hovered: false, visible: true)
                .background(LEDOrbView.panelColor(dark: scheme == .dark))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline(scheme)) }
                .scaleEffect(2).frame(width: 110, height: 88)
            PanelThumbnail(store: store)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.primary(scheme).opacity(scheme == .dark ? 0.045 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)

        SettingsCard {
            SettingsRow(title: "显示方式", divider: false,
                        help: "刘海：悬停展开，无刘海的外接屏显示在屏幕上沿。圆环：点击展开，点外面或按 Esc 收回。常驻浮窗和圆环拖放都保持当前模式；仅状态栏从菜单栏打开。") {
                SettingsChips(options: [(PanelPlacement.top, "刘海"), (.floating, "浮窗"), (.orb, "圆环"), (.menuBar, "状态栏")],
                              selection: Binding(get: { store.placement }, set: { store.setPlacement($0) }))
            }
            if store.placement == .top {
                SettingsRow(title: "刘海显示器") {
                    Picker("", selection: Binding(get: { store.preferences.preferredDisplay ?? "" }, set: { store.setDisplay($0) })) {
                        Text("自动 · 系统主显示器").tag("")
                        ForEach(displayState.choices) { display in Text(display.name).tag(display.id) }
                        if let saved = store.preferences.preferredDisplay, !displayState.choices.contains(where: { $0.id == saved }) {
                            Text("已断开的显示器 · 暂用主屏").tag(saved)
                        }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            SettingsRow(title: "配色", help: "刘海、展开面板和浮窗用同一套配色。") {
                SettingsChips(options: [(PanelTheme.dark, "深色"), (.light, "浅色"), (.system, "跟随系统")],
                              selection: Binding(get: { store.themeChoice }, set: { store.setTheme($0) }))
            }
            if store.placement == .orb {
                SettingsRow(title: "圆环外观", help: "圆环模式收起时的样子，都是 44pt；点一下看任务，拖动移动。") {
                    SettingsChips(options: [(OrbAppearance.ring, "点阵"), (.twinArc, "渐隐双弧")],
                                  selection: Binding(get: { store.orbAppearance }, set: { store.setOrbAppearance($0) }))
                }
            }
            SettingsRow(title: "比例", help: "面板和浮窗的大小，每 5% 一档；圆环始终 44pt。") {
                SettingsScaleBar(percent: Binding(get: { (store.preferences.resolvedDisplayScale * 100).rounded() }, set: { store.setScale($0 / 100) }))
            }
            SettingsRow(title: "窗口跑丢了", help: "把圆环、浮窗和设置窗口移回当前屏幕。") {
                Button("找回窗口", action: recoverWindows)
            }
        }

        if store.demo {
            SettingsCard {
                SettingsRow(title: "动画预览", divider: false, help: "用示例任务体验圆环状态，不影响真实任务。") {
                    HStack(spacing: 6) {
                        Button("运行") { store.previewDemoPhase(.running) }
                        Button("待回答") { store.previewDemoPhase(.waiting) }
                        Button("完成") { store.previewDemoPhase(.completed) }
                        Button("出错") { store.previewDemoPhase(.failed) }
                        Button("恢复") { store.previewDemoPhase(nil) }
                    }
                }
            }
        }
    }

    // MARK: 任务

    @ViewBuilder private var tasksPage: some View {
        // 顶上一行状态：在不在刷新、上次刷新多久前，暂停和立即刷新放这里。
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: 10) {
                let color = store.paused ? warning : Color(nsColor: LEDOrbView.toneColor(.done, dark: scheme == .dark))
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 8, height: 8)
                Text(store.paused ? "已暂停刷新" : "正在监控").font(.system(size: 13.5, weight: .semibold))
                if let last = store.lastRefresh {
                    Text("· 上次刷新 \(Self.ago(last, now: context.date))").font(.system(size: 13.5)).foregroundStyle(secondary)
                }
                Spacer(minLength: 8)
                LEDSwitch(isOn: $store.paused, label: "暂停刷新")
                Text("暂停").font(.system(size: 13.5)).foregroundStyle(secondary)
                SettingsRefreshButton(store: store, state: store.refreshState)
            }
            .padding(.horizontal, 16).frame(height: 52)
            .background(Palette.primary(scheme).opacity(scheme == .dark ? 0.045 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        }

        SettingsCard {
            SettingsRow(title: "列表显示几条", divider: false, help: "控制列表高度，默认 4 条。任务少时自动收缩，超出时滚动；所有显示方式共用。") {
                Picker("", selection: Binding(get: { store.preferences.resolvedVisibleTaskCount }, set: { store.setVisibleTaskCount($0) })) {
                    ForEach(MonitorPreferences.visibleTaskCountRange, id: \.self) { count in Text("\(count) 条").tag(count) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            SettingsToggleRow(title: "自动加入新任务", isOn: Binding(get: { store.preferences.autoMonitor }, set: { store.setAutoMonitor($0) }),
                              help: "新建并开始执行的任务自动加入列表；你手动移出的不会再自动加回来。")
            SettingsRow(title: "自动移出已结束", help: "只移出已停止、已完成的任务，按最近活动算。再次运行会自动回来；用＋重新加入的会保留。关掉会恢复已自动移出的任务。") {
                Picker("", selection: Binding(get: { store.preferences.resolvedFinishedRetentionDays }, set: { store.setFinishedRetentionDays($0) })) {
                    ForEach(MonitorPreferences.finishedRetentionOptions, id: \.self) { days in
                        Text(days == 0 ? "关闭" : "\(days) 天无活动后").tag(days)
                    }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }

    // MARK: 用量

    @ViewBuilder private var usagePage: some View {
        // 和面板里的用量卡片同一份内容。
        if store.codexUsage != nil || store.quota != nil {
            UsageCard(store: store, origin: .codex, closable: false)
                .background(Palette.primary(scheme).opacity(scheme == .dark ? 0.03 : 0.03), in: RoundedRectangle(cornerRadius: 16))
        }
        if store.claudeUsage != nil {
            UsageCard(store: store, origin: .claudeCode, closable: false)
                .background(Palette.primary(scheme).opacity(scheme == .dark ? 0.03 : 0.03), in: RoundedRectangle(cornerRadius: 16))
        }
        SettingsCard {
            SettingsRow(title: store.quota.map { "额度更新于 \($0.observedAt.formatted(date: .omitted, time: .shortened))" } ?? "还没有读到额度",
                        divider: false,
                        help: "每 60 秒独立读取账户额度，不用发消息；切换 Codex 账号后可以点刷新。暂停任务刷新不影响额度读取。") {
                Button(store.quotaRefreshing ? "刷新中…" : "刷新额度") { store.refreshQuota(force: true) }
                    .disabled(store.demo || store.quotaRefreshing)
            }
        }
    }

    // MARK: 设备

    @ViewBuilder private var devicePage: some View {
        let lan = store.preferences.resolvedDeviceLANAccess
        if lan, let token = store.preferences.deviceToken {
            HStack(spacing: 14) {
                Text("口令").font(.system(size: 13.5, weight: .medium))
                Text(token).font(.system(size: 28, weight: .heavy, design: .monospaced)).tracking(5).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("复制") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string)
                }
                Button("换一个") { store.regenerateDeviceToken() }.help("换完旧口令立刻失效")
            }
            .padding(.horizontal, 16).frame(height: 64)
            .background(Palette.primary(scheme).opacity(scheme == .dark ? 0.045 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        }

        SettingsCard {
            SettingsToggleRow(title: "允许局域网设备读取",
                              isOn: Binding(get: { lan }, set: { store.setDeviceLANAccess($0) }), divider: false,
                              help: "同一 Wi-Fi 下的 Tab5 等设备能自动找到这台电脑，带上口令读取任务状态、用量和主题，或打开某个任务（和面板里点一下一样）。关着时只有本机能读。")
            SettingsToggleRow(title: "给任务标题",
                              isOn: Binding(get: { store.preferences.resolvedDeviceShareTitles }, set: { store.setDeviceShareTitles($0) }),
                              help: "关掉后设备只看到来源、状态和计时，看不到任务标题。")
            SettingsRow(title: "访问地址") {
                if let problem = store.deviceServiceProblem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(warning)
                } else {
                    Text(lan ? DeviceAPIServer.lanAddress().map { "\($0):\(DeviceAPI.port)" } ?? "没连上局域网" : "127.0.0.1:\(DeviceAPI.port)（仅本机）")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).textSelection(.enabled)
                }
            }
            SettingsRow(title: "最近读取", help: "最近一次局域网设备成功读取的地址和时间；本机读取不算。") {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let read = deviceAccess.lastRead {
                        let fresh = context.date.timeIntervalSince(read.at) < 30
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(fresh ? Color(nsColor: LEDOrbView.toneColor(.done, dark: scheme == .dark)) : Palette.primary(scheme).opacity(0.25))
                                .frame(width: 8, height: 8)
                            Text("\(read.host) · \(Self.ago(read.at, now: context.date))").font(.system(size: 13, design: .monospaced))
                        }
                    } else {
                        Text("还没有设备读取过").font(.system(size: 13)).foregroundStyle(secondary)
                    }
                }
            }
            SettingsRow(title: "接口文档") {
                Button("打开") {
                    if let url = URL(string: "https://github.com/BuTangTang/Codex-Top/blob/main/docs/REQ-005-%E8%AE%BE%E5%A4%87%E8%AF%BB%E5%8F%96%E6%8E%A5%E5%8F%A3/%E6%8E%A5%E5%8F%A3%E6%96%87%E6%A1%A3.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: 数据与启动

    @ViewBuilder private var systemPage: some View {
        SettingsCard {
            SettingsToggleRow(title: "登录 Mac 时启动",
                              isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: { setLoginEnabled($0) }),
                              divider: false)
                .disabled(store.demo)
            if !store.demo && loginStatus == .requiresApproval {
                SettingsRow(title: "等待系统允许") {
                    Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError {
                SettingsRow(title: loginError) { EmptyView() }.foregroundStyle(warning)
            }
            SettingsRow(title: "Codex 数据目录", help: store.demo ? "演示模式不读取本机任务" : store.rootURL.path) {
                Text(store.demo ? "演示模式" : Self.shortPath(store.rootURL)).font(.system(size: 13, design: .monospaced)).foregroundStyle(secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("选择…") { store.chooseRoot() }.disabled(store.demo)
            }
        }

        SettingsCard {
            SettingsToggleRow(title: "监控 Claude Code 会话",
                              isOn: Binding(get: { store.preferences.resolvedClaudeEnabled }, set: { store.setClaudeEnabled($0) }),
                              divider: false,
                              help: store.claudeInstalled ? "只读会话记录和运行登记，不改 Claude Code 的文件。" : "没有检测到 Claude Code")
                .disabled(store.demo || !store.claudeInstalled)
            SettingsRow(title: "Claude Code 数据目录", help: store.claudeRootURL.path) {
                Text(store.demo ? "演示模式" : store.claudeInstalled ? Self.shortPath(store.claudeRootURL) : "未检测到")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(secondary).lineLimit(1).truncationMode(.middle)
                Button("选择…") { store.chooseClaudeRoot() }.disabled(store.demo)
            }
            SettingsToggleRow(title: "显示“等待你批准”",
                              isOn: Binding(get: { store.claudeHookInstalled == true }, set: { enabled in
                                  if enabled { confirmClaudeHook = true } else { store.setClaudeHook(false) }
                              }),
                              help: store.claudeHookInstalled == nil
                                ? "Claude Code 的 settings.json 不是标准 JSON，无法添加钩子。"
                                : "在 Claude Code 设置里加一条通知钩子，只记会话编号和时间，不记内容；改之前备份，关掉就删掉。之后新启动的会话才生效。")
                .disabled(store.demo || !store.claudeInstalled || store.claudeHookInstalled == nil)
                .onAppear { store.refreshClaudeHookStatus() }
                .alert("在 Claude Code 设置里加一个通知钩子？", isPresented: $confirmClaudeHook) {
                    Button("加上") { store.setClaudeHook(true) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("会在 settings.json 的 hooks 里加一条，只在 Claude Code 弹出“需要你批准”或“需要你填写”时运行，只记下会话编号和时间，不记内容。改之前会备份，关掉开关就删掉这一条。之后新启动的会话才生效。")
                }
        }

        if let notice = store.notice {
            Text(notice).font(.system(size: 13)).foregroundStyle(warning).padding(.horizontal, 4)
        }

        SettingsCard {
            SettingsRow(title: Self.versionText, divider: false, help: "恢复前会先备份现在的设置。") {
                Button("恢复默认设置") { store.restorePreferences() }
            }
        }
    }

    /// 家目录写成 ~，路径太长时中间省略。
    static func shortPath(_ url: URL) -> String {
        let path = url.path, home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Codex Top \(version)（构建 \(build)）"
    }
}

/// 立即刷新：沿用手动刷新及忙碌禁用行为。
private struct SettingsRefreshButton: View {
    let store: TaskStore
    @ObservedObject var state: TaskRefreshState
    var body: some View {
        Button(state.isRefreshing ? "刷新中…" : "立即刷新") {
            store.refreshQuota(force: true)
            Task { await store.refresh() }
        }.disabled(state.isRefreshing)
    }
}

/// 显示页预览里的面板缩略图：真实关注列表的前三条，跟着配色走。
private struct PanelThumbnail: View {
    @ObservedObject var store: TaskStore
    var body: some View {
        let scheme = store.theme.colorScheme, dark = scheme == .dark
        let rows = Array((store.active + store.freshTasks).prefix(3))
        VStack(alignment: .leading, spacing: 5) {
            Text("监控任务").font(.system(size: 11, weight: .bold))
            Rectangle().fill(Palette.hairline(scheme)).frame(height: 1)
            ForEach(rows, id: \.id) { task in
                let phase = store.graph.activity(for: task).phase
                // 和任务行小灯一样：在跑蓝、等你琥珀、失败红、刚完成绿。
                let color = store.freshFinished[task.id] != nil ? Color(nsColor: LEDOrbView.toneColor(.done, dark: dark))
                    : phase == .waiting ? Color(nsColor: LEDOrbView.toneColor(.waiting, dark: dark))
                    : phase == .failed ? Color(nsColor: LEDOrbView.toneColor(.failed, dark: dark))
                    : UsageCardText.blue(dark: dark)
                HStack(spacing: 6) {
                    Rectangle().fill(color).frame(width: 3, height: 11)
                    Text(task.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
            }
            if rows.isEmpty { Text("还没有关注的任务").font(.system(size: 11)).foregroundStyle(Palette.secondary(scheme)) }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 190, height: 88, alignment: .topLeading)
        .background(LEDOrbView.panelColor(dark: dark), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline(scheme)) }
    }
}
