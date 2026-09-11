import SwiftUI
import ServiceManagement
import CodexTopCore

struct CompactView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.compactMonitorTypography) private var compactTypography
    let notchWidth: CGFloat
    var drawsSurface = true
    var open: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let summary = CompactMonitorSummary(status: store.statusSummary, paused: store.paused, quota: store.quota, now: context.date)
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(summary.leftPhase.tint(store.theme.colorScheme)).frame(width: 5, height: 5)
                    Text(summary.leftText).font(.system(size: compactTypography ? 12 : 13, weight: .regular))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }.padding(.horizontal, 6).frame(maxWidth: .infinity)
                if notchWidth > 0 { Color.clear.frame(width: notchWidth) }
                else { Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(width: 1, height: 12) }
                HStack(spacing: 4) {
                    if summary.isQuotaStale || store.quotaWarning != nil {
                        Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                    }
                    VStack(spacing: 0) {
                        ForEach(summary.quotaLines.indices, id: \.self) { index in
                            Text(summary.quotaLines[index])
                                .font(.system(size: summary.quotaLines.count > 1 ? 11 : compactTypography ? 12 : 13, weight: .regular))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                }.padding(.horizontal, 6).frame(maxWidth: .infinity)
            }
            .foregroundStyle(Palette.primary(store.theme.colorScheme))
            .frame(maxHeight: .infinity)
            .background { if drawsSurface { GlassFill() } }
            .clipShape(RoundedRectangle(cornerRadius: notchWidth > 0 ? 10 : 14))
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("刘海模式，\(summary.leftText)，剩余额度：\(summary.quotaLines.joined(separator: "，"))")
            .accessibilityAddTraits(.isButton)
            .help("\(store.runningCount) 个运行中 · \(store.attentionCount) 个待处理\n" + (store.quota.map { UsageText.details($0, at: context.date) } ?? "额度暂无数据") + "\n移入或点击展开任务，面板额度入口可打开用量网页。")
        }
    }
}

struct TaskPickerView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.compactMonitorTypography) private var compactTypography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var close: () -> Void
    @State private var search = ""
    @State private var filter = "全部"
    @State private var draft: Set<String>
    private let original: Set<String>
    init(store: TaskStore, close: @escaping () -> Void) {
        self.store = store; self.close = close; self.original = store.preferences.selectedIDs
        _draft = State(initialValue: store.preferences.selectedIDs)
    }
    private var filtered: [CodexTask] {
        store.graph.roots.filter { task in
            let phase = store.graph.activity(for: task).phase
            let statusMatch = filter == "全部" || (filter == "运行中" && phase == .running) || (filter == "待处理" && [.waiting, .failed].contains(phase)) || (filter == "已结束" && phase.isFinished)
            return statusMatch && (search.isEmpty || task.title.localizedCaseInsensitiveContains(search) || task.project.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        ScaledPanel(scale: store.uiScale) {
        PanelSurface {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择监控任务").font(PanelFonts.readable(17, minimum: 15, scale: store.uiScale, weight: .semibold, compact: compactTypography))
                    Text("全部任务").font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                }
                Spacer()
                Text("\(store.graph.roots.count) 个任务").font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary(store.theme.colorScheme))
                TextField("搜索任务名称或项目", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("搜索任务名称或项目")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.font(PanelFonts.readable(16, scale: store.uiScale, compact: compactTypography)).padding(.horizontal, 12).frame(height: 38)
                .background(Palette.primary(store.theme.colorScheme).opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline(store.theme.colorScheme), lineWidth: 0.7)).padding(.horizontal, 22)
            HStack(spacing: 9) {
                ForEach(["全部", "运行中", "待处理", "已结束"], id: \.self) { item in
                    Button { filter = item } label: {
                        Text(item).font(PanelFonts.readable(14, scale: store.uiScale, weight: filter == item ? .medium : .regular, compact: compactTypography)).foregroundStyle(filter == item ? .white : Palette.primary(store.theme.colorScheme)).frame(maxWidth: .infinity).frame(height: 32)
                            .background(filter == item ? Palette.accent : Palette.primary(store.theme.colorScheme).opacity(0.045), in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(item).accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }.padding(.horizontal, 22).padding(.vertical, 10)
            Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: 0.5).padding(.horizontal, 26)
            HStack {
                Button {
                    MonitoringPolicy.selectVisible(Set(filtered.map(\.id)), selected: &draft)
                } label: {
                    let ids = Set(filtered.map(\.id))
                    Image(systemName: !ids.isEmpty && ids.isSubset(of: draft) ? "checkmark.square.fill" : !ids.isDisjoint(with: draft) ? "minus.square.fill" : "square").font(.system(size: 22)).foregroundStyle(Palette.accent)
                    Text("全选当前结果")
                }.buttonStyle(.plain).disabled(filtered.isEmpty)
                Spacer(); Text("\(filtered.count) 项").foregroundStyle(Palette.secondary(store.theme.colorScheme))
            }.font(PanelFonts.readable(15, scale: store.uiScale, compact: compactTypography)).padding(.horizontal, 28).frame(height: 46)
            Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: 0.5).padding(.horizontal, 26)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { task in
                        Toggle(isOn: Binding(get: { draft.contains(task.id) }, set: { if $0 { draft.insert(task.id) } else { draft.remove(task.id) } })) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).font(PanelFonts.readable(16, minimum: 14, scale: store.uiScale, weight: .medium, compact: compactTypography)).lineLimit(1).truncationMode(.tail)
                                    Text(task.project).font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme)).lineLimit(1).truncationMode(.tail)
                                }
                                Spacer()
                                let phase = store.graph.activity(for: task).phase
                                HStack(spacing: 6) {
                                    Circle().fill(phase.tint(store.theme.colorScheme)).frame(width: 9, height: 9)
                                    TaskPhaseLabel(phase: phase).font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).lineLimit(1)
                                }.fixedSize(horizontal: true, vertical: false)
                            }
                        }.toggleStyle(.checkbox).controlSize(.large).padding(.horizontal, 24).frame(height: 54)
                        Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: 0.5).padding(.horizontal, 26)
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "没有符合条件的任务" : "没有搜索结果", systemImage: "magnifyingglass", description: Text("尝试其他任务名、项目名或筛选条件"))
                    }
                }
            }
            Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: 0.5)
            HStack {
                Text("已选择 \(draft.count) 项").foregroundStyle(Palette.primary(store.theme.colorScheme))
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction).controlSize(.large)
                Button("确认选择") { store.applySelection(draft, original: original); close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            }.font(PanelFonts.readable(15, scale: store.uiScale, compact: compactTypography)).padding(.horizontal, 26).frame(height: 66)
        }.tint(Palette.accent)
        }.environment(\.colorScheme, store.theme == .light ? .light : .dark)
            .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: store.theme)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: TaskStore
    var displays: [DisplayChoice]
    var recoverWindows: () -> Void
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    private func refreshLoginStatus() {
        let current: SMAppService.Status = store.demo ? .notRegistered : SMAppService.mainApp.status
        if current != loginStatus { loginError = nil }
        loginStatus = current
    }
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
        Form {
            Section("外观") {
                Picker("配色", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) {
                    Text("深色").tag(PanelTheme.dark)
                    Text("浅色玻璃").tag(PanelTheme.light)
                }.pickerStyle(.segmented)
                Text("刘海、展开面板与浮窗使用同一主题。").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("显示比例")
                        Spacer()
                        Text("\(Int((store.preferences.resolvedScale * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button("100%") { store.setScale(1) }
                            .accessibilityLabel("恢复显示比例为100%")
                    }
                    HStack(spacing: 10) {
                        Text("60%").font(.caption).foregroundStyle(.secondary)
                        MonitorScaleSlider(percentage: Binding(get: { (store.preferences.resolvedScale * 100).rounded() }, set: { store.setScale($0 / 100) }))
                            .frame(maxWidth: .infinity).frame(height: 22)
                        Text("120%").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("拖动调整，每 5% 一档；圆环保持 44pt。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.demo {
                Section("动画预览") {
                    Text("用示例任务体验圆环状态，不影响真实任务。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("运行") { store.previewDemoPhase(.running) }
                        Button("待回答") { store.previewDemoPhase(.waiting) }
                        Button("完成") { store.previewDemoPhase(.completed) }
                        Button("出错") { store.previewDemoPhase(.failed) }
                    }
                    Button("恢复示例状态") { store.previewDemoPhase(nil) }
                }
            }
            Section("任务") {
                Toggle("自动监控新任务", isOn: Binding(get: { store.preferences.autoMonitor }, set: { store.setAutoMonitor($0) }))
                Text("新建并开始执行后加入列表。手动取消关注的任务不会再次自动加入。").font(.caption).foregroundStyle(.secondary)
                Toggle("暂停任务刷新", isOn: $store.paused)
                Button("立即刷新") { store.refreshQuota(force: true); Task { await store.refresh() } }.disabled(store.refreshing)
            }
            Section("账户额度") { UsageSettingsContent(store: store) }
            Section("显示位置") {
                Picker("显示方式", selection: Binding(get: { store.placement }, set: { store.setPlacement($0) })) {
                    Text("刘海模式").tag(PanelPlacement.top)
                    Text("常驻浮窗").tag(PanelPlacement.floating)
                    Text("圆环").tag(PanelPlacement.orb)
                    Text("仅状态栏").tag(PanelPlacement.menuBar)
                }.pickerStyle(.segmented)
                Picker("刘海显示器", selection: Binding(get: { store.preferences.preferredDisplay ?? "" }, set: { store.setDisplay($0) })) {
                    Text("自动 · 系统主显示器").tag("")
                    ForEach(displays) { display in Text(display.name).tag(display.id) }
                    if let saved = store.preferences.preferredDisplay, !displays.contains(where: { $0.id == saved }) {
                        Text("已断开的显示器 · 暂用主屏").tag(saved)
                    }
                }
                Text("刘海模式悬停展开；无刘海的外接屏显示在屏幕上沿。圆环点击展开、点外或按 Esc 缩回，拖至上沿仍留桌面。常驻浮窗与圆环拖放均保持当前模式，仅状态栏需从菜单手动选择。").font(.caption).foregroundStyle(.secondary)
                Button("找回窗口", action: recoverWindows)
            }
            Section("数据与启动") {
                HStack {
                    Text("Codex 数据目录"); Spacer(); Button("选择…") { store.chooseRoot() }.disabled(store.demo)
                }
                Text(store.demo ? "演示模式：不读取本机任务" : store.rootURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("登录 Mac 时启动", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { enabled in setLoginEnabled(enabled) }
                )).disabled(store.demo)
                if !store.demo && loginStatus == .requiresApproval {
                    Text("已登记，等待系统允许。请在系统设置的登录项中允许 Codex Top。").font(.caption).foregroundStyle(.orange)
                    Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                Text("状态来自本机日志。长时间没有新活动会显示未知；请在 Codex 中处理输入和批准。").font(.caption).foregroundStyle(.secondary)
                if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                Button("备份并恢复默认设置") { store.restorePreferences() }
            }
        }.formStyle(.grouped).environment(\.colorScheme, store.theme == .light ? .light : .dark)
            .onAppear { refreshLoginStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginStatus() }
    }
}
