import SwiftUI
import ServiceManagement
import CodexTopCore

struct CompactView: View {
    @ObservedObject var store: TaskStore
    let notchWidth: CGFloat
    var drawsSurface = true
    var open: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.paused ? Color.gray : TaskPhase.running.tint).frame(width: 6, height: 6)
                Text(store.paused ? "已暂停" : "\(store.runningCount) 运行中").font(.system(size: 13, weight: .medium))
            }.frame(maxWidth: .infinity)
            if notchWidth > 0 { Color.black.frame(width: notchWidth) }
            else { Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 12) }
            HStack(spacing: 6) {
                Circle().fill(store.attentionCount > 0 ? TaskPhase.waiting.tint : .gray).frame(width: 6, height: 6)
                Text(store.attentionCount > 0 ? "\(store.attentionCount) 待处理" : store.demo ? "演示模式" : "Codex Top").font(.system(size: 13, weight: .medium))
            }.frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white.opacity(0.92))
        .frame(maxHeight: .infinity)
        .background(drawsSurface ? .black : .clear)
        .clipShape(RoundedRectangle(cornerRadius: notchWidth > 0 ? 10 : 14))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex Top，\(store.runningCount) 个任务运行中，\(store.attentionCount) 个待处理")
        .accessibilityAddTraits(.isButton)
    }
}

struct TaskPickerView: View {
    @ObservedObject var store: TaskStore
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
                    Text("选择监控任务").font(PanelFonts.header)
                    Text("全部任务").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Text("\(store.graph.roots.count) 个任务").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索任务名称或项目", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("搜索任务名称或项目")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.font(.system(size: 14)).padding(.horizontal, 12).frame(height: 38)
                .background(Palette.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 0.7)).padding(.horizontal, 22)
            HStack(spacing: 9) {
                ForEach(["全部", "运行中", "待处理", "已结束"], id: \.self) { item in
                    Button { filter = item } label: {
                        Text(item).font(.system(size: 13, weight: filter == item ? .medium : .regular)).foregroundStyle(filter == item ? .white : Palette.primary).frame(maxWidth: .infinity).frame(height: 32)
                            .background(filter == item ? Palette.accent : Palette.primary.opacity(0.045), in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(item).accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }.padding(.horizontal, 22).padding(.vertical, 10)
            Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.horizontal, 26)
            HStack {
                Button {
                    MonitoringPolicy.selectVisible(Set(filtered.map(\.id)), selected: &draft)
                } label: {
                    let ids = Set(filtered.map(\.id))
                    Image(systemName: !ids.isEmpty && ids.isSubset(of: draft) ? "checkmark.square.fill" : !ids.isDisjoint(with: draft) ? "minus.square.fill" : "square").font(.system(size: 22)).foregroundStyle(Palette.accent)
                    Text("全选当前结果")
                }.buttonStyle(.plain).disabled(filtered.isEmpty)
                Spacer(); Text("\(filtered.count) 项").foregroundStyle(Palette.secondary)
            }.font(.system(size: 14)).padding(.horizontal, 28).frame(height: 46)
            Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.horizontal, 26)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { task in
                        Toggle(isOn: Binding(get: { draft.contains(task.id) }, set: { if $0 { draft.insert(task.id) } else { draft.remove(task.id) } })) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).font(PanelFonts.task).lineLimit(1)
                                    Text(task.project).font(PanelFonts.detail).foregroundStyle(Palette.secondary).lineLimit(1)
                                }
                                Spacer()
                                let phase = store.graph.activity(for: task).phase
                                HStack(spacing: 6) {
                                    Circle().fill(phase.tint).frame(width: 9, height: 9)
                                    Text(phase.label).font(.system(size: 13)).foregroundStyle(phase.tint)
                                }
                            }
                        }.toggleStyle(.checkbox).controlSize(.large).padding(.horizontal, 24).frame(height: 54)
                        Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.horizontal, 26)
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "没有符合条件的任务" : "没有搜索结果", systemImage: "magnifyingglass", description: Text("尝试其他任务名、项目名或筛选条件"))
                    }
                }
            }
            Rectangle().fill(Palette.hairline).frame(height: 0.5)
            HStack {
                Text("已选择 \(draft.count) 项").foregroundStyle(Palette.primary)
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction).controlSize(.large)
                Button("确认选择") { store.applySelection(draft, original: original); close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            }.font(.system(size: 14)).padding(.horizontal, 26).frame(height: 66)
        }.tint(Palette.accent)
        }.environment(\.colorScheme, store.theme == .light ? .light : .dark)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: TaskStore
    var displays: [DisplayChoice]
    var recoverWindows: () -> Void
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        Form {
            Section("外观") {
                Picker("配色", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) {
                    Text("深色").tag(PanelTheme.dark)
                    Text("浅色玻璃").tag(PanelTheme.light)
                }.pickerStyle(.segmented)
                Text("顶部刘海保持黑色；展开面板与浮窗同步换色。").font(.caption).foregroundStyle(.secondary)
                Picker("显示比例", selection: Binding(get: { store.preferences.resolvedScale }, set: { store.setScale($0) })) {
                    Text("80%").tag(0.8)
                    Text("90%").tag(0.9)
                    Text("100%").tag(1.0)
                }.pickerStyle(.segmented)
            }
            Section("任务") {
                Toggle("自动监控新任务", isOn: Binding(get: { store.preferences.autoMonitor }, set: { store.setAutoMonitor($0) }))
                Text("新建并开始执行后加入列表。手动取消关注的任务不会再次自动加入。").font(.caption).foregroundStyle(.secondary)
                Toggle("暂停刷新", isOn: $store.paused)
                Button("立即刷新") { Task { await store.refresh() } }.disabled(store.refreshing)
            }
            Section("显示位置") {
                Picker("显示方式", selection: Binding(get: { store.placement }, set: { store.setPlacement($0) })) {
                    Text("顶部").tag(PanelPlacement.top)
                    Text("常驻浮窗").tag(PanelPlacement.floating)
                    Text("圆环").tag(PanelPlacement.orb)
                    Text("仅状态栏").tag(PanelPlacement.menuBar)
                }.pickerStyle(.segmented)
                Picker("顶部显示器", selection: Binding(get: { store.preferences.preferredDisplay ?? "" }, set: { store.setDisplay($0) })) {
                    Text("自动 · 系统主显示器").tag("")
                    ForEach(displays) { display in Text(display.name).tag(display.id) }
                    if let saved = store.preferences.preferredDisplay, !displays.contains(where: { $0.id == saved }) {
                        Text("已断开的显示器 · 暂用主屏").tag(saved)
                    }
                }
                Text("顶部和圆环悬停展开；常驻浮窗移开鼠标也不隐藏。拖动浮窗左上角手柄或圆环，靠近屏幕顶部松手收进状态栏。").font(.caption).foregroundStyle(.secondary)
                Button("找回窗口", action: recoverWindows)
            }
            Section("数据与启动") {
                HStack {
                    Text("Codex 数据目录"); Spacer(); Button("选择…") { store.chooseRoot() }.disabled(store.demo)
                }
                Text(store.demo ? "演示模式：不读取本机任务" : store.rootURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("登录 Mac 时启动", isOn: Binding(get: { loginEnabled }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                        if SMAppService.mainApp.status == .requiresApproval { loginError = "请在系统设置的登录项中允许 Codex Top。"; SMAppService.openSystemSettingsLoginItems() }
                    } catch { loginError = "无法修改登录项。请将应用放入 Applications 后重试。" }
                })).disabled(store.demo)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                Text("状态来自本机日志。长时间没有新活动会显示未知；请在 Codex 中处理输入和批准。").font(.caption).foregroundStyle(.secondary)
                if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                Button("备份并恢复默认设置") { store.restorePreferences() }
            }
        }.formStyle(.grouped).environment(\.colorScheme, store.theme == .light ? .light : .dark)
    }
}
