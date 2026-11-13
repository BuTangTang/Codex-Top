import SwiftUI
import ServiceManagement
import CodexTopCore

/// 仅此按钮观察刷新过程，圆环和任务列表继续只观察展示数据的变化。
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
                Button("取消当前结果") { draft.subtract(filtered.map(\.id)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .disabled(Set(filtered.map(\.id)).isDisjoint(with: draft))
                    .help("仅取消当前筛选结果的勾选，确认选择后保存")
                Spacer(); Text("\(filtered.count) 项").foregroundStyle(Palette.secondary(store.theme.colorScheme))
            }.font(PanelFonts.readable(15, scale: store.uiScale, compact: compactTypography)).padding(.horizontal, 28).frame(height: 46)
            Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: 0.5).padding(.horizontal, 26)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { task in
                        Toggle(isOn: Binding(get: { draft.contains(task.id) }, set: { if $0 { draft.insert(task.id) } else { draft.remove(task.id) } })) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(task.title).font(PanelFonts.readable(16, minimum: 14, scale: store.uiScale, weight: .medium, compact: compactTypography)).lineLimit(1).truncationMode(.tail)
                                        if store.pickerShowsSourceMarks { SourceMark(origin: task.origin, scale: store.uiScale) }
                                    }
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

/// 来源标记：CX 用应用蓝色方块（2026-11-08 用户改定），CC 为橙色圆角。只在列表里两种来源并存时显示。
struct SourceMark: View {
    let origin: TaskOrigin
    let scale: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // D-86：浅底彩字、同一圆角。2026-11-09 用户觉得不够明显：底色加深、深色模式字更亮、加粗。
        let tint = origin == .codex ? Palette.accent : Color(red: 0.85, green: 0.47, blue: 0.24)
        let text = colorScheme == .dark
            ? (origin == .codex ? Color(red: 0.49, green: 0.72, blue: 1) : Color(red: 0.97, green: 0.64, blue: 0.42)) : tint
        Text(origin.mark)
            .font(.system(size: 10 * max(1, scale), weight: .bold))
            .foregroundStyle(text)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(colorScheme == .dark ? 0.30 : 0.20), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .accessibilityLabel(origin.displayName)
    }
}
