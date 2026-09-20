import SwiftUI
import CodexTopCore

@MainActor final class MonitorPanelState: ObservableObject {
    @Published var expandedFinished = false
    @Published var floatingFinished = false
}

struct MonitorView: View {
    @ObservedObject var store: TaskStore
    let compact: Bool
    @Binding var showFinished: Bool
    var drawsSurface = true
    var animationsActive = true
    var collapse: (() -> Void)? = nil
    var pickTasks: () -> Void
    var settings: () -> Void
    var finishedChanged: () -> Void = {}
    var draggable = false
    var dragStarted: (CGPoint) -> Void = { _ in }
    var dragMoved: (CGPoint) -> Void = { _ in }
    var dragEnded: (CGPoint) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactMonitorTypography) private var windowCompactTypography
    private var compactTypography: Bool { compact || windowCompactTypography }

    private var visibleTaskIDs: [String] {
        (store.active + (showFinished ? store.finished : [])).map(\.id)
    }

    var body: some View {
        Group {
            if drawsSurface { PanelSurface { panelContent } }
            else { panelContent }
        }
        .foregroundStyle(Palette.primary(store.theme.colorScheme))
        .tint(Palette.accent)
        .environment(\.colorScheme, store.theme == .light ? .light : .dark)
        .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: store.theme)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
                header
                separator
                if store.loading {
                    ProgressView("正在读取任务…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.selected.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.stack").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                        Text("选择你想关注的任务").font(PanelFonts.readable(16, minimum: 14, scale: store.uiScale, weight: .medium, compact: compactTypography))
                        Text(store.preferences.autoMonitor ? "新建并运行的任务会自动加入" : "自动监控已关闭，可手动选择任务").font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                        Button("选择任务", action: pickTasks).controlSize(.large)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(visibleTaskIDs, id: \.self) { taskID in
                                    VStack(spacing: 0) {
                                        MonitorTaskRow(store: store, taskID: taskID, compact: compact, animationsActive: animationsActive)
                                        separator
                                    }.id(taskID)
                                        .transition(.opacity)
                                }
                            }
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: visibleTaskIDs)
                        }.scrollIndicators(.automatic).frame(maxHeight: .infinity)
                        if !store.finished.isEmpty {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { showFinished.toggle() }
                                finishedChanged()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "chevron.down").rotationEffect(.degrees(showFinished ? 180 : 0))
                                        .font(.system(size: 11, weight: .medium)).frame(width: 24)
                                    Text("已结束 \(store.finished.count)").font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography))
                                    Spacer()
                                }.foregroundStyle(Palette.secondary(store.theme.colorScheme)).padding(.horizontal, 16).frame(height: PanelMetrics.disclosure)
                            }.buttonStyle(QuietRowStyle())
                        }
                    }
                }
                if let warning = store.sourceWarning {
                    Label(warning, systemImage: "exclamationmark.circle").font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.primary(store.theme.colorScheme))
                        .lineLimit(3).padding(.horizontal, 20).padding(.vertical, 10)
                }
                if let notice = store.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Text(notice).font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                        Spacer(minLength: 0)
                        Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 22, height: 22) }.buttonStyle(QuietButtonStyle())
                    }.padding(.horizontal, 20).padding(.vertical, 10)
                }
                if !compact { footer }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("监控任务").font(PanelFonts.readable(17, minimum: 15, scale: store.uiScale, weight: .semibold, compact: compactTypography)).lineLimit(1)
            Text("\(store.selected.count)").font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.selected.count)
            if compact && store.demo { Text("演示").font(.system(size: 12)).foregroundStyle(Palette.secondary(store.theme.colorScheme)) }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Button(action: pickTasks) {
                    headerIcon("plus")
                }.headerButtonHitArea().help("搜索和选择监控任务").accessibilityLabel("选择任务")
                moreMenu
            }
        }.buttonStyle(QuietButtonStyle()).padding(.horizontal, 16)
            .frame(height: compact ? PanelMetrics.floatingHeader : PanelMetrics.expandedHeader)
            .overlayPreferenceValue(HeaderButtonBounds.self) { anchors in
                if draggable {
                    GeometryReader { geometry in
                        WindowDragHandle(started: dragStarted, moved: dragMoved, ended: dragEnded,
                                         excludedFrames: anchors.map { geometry[$0] }, enabled: animationsActive)
                    }
                }
            }
            .contextMenu { Button("选择任务", action: pickTasks); Button("监控设置", action: settings) }
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.primary(store.theme.colorScheme).opacity(0.8))
            .frame(width: 28, height: 30)
    }

    private var moreMenu: some View {
        Menu {
            Menu("显示方式") {
                Picker("显示方式", selection: Binding(get: { store.placement }, set: { placement in
                    if placement != store.placement { store.setPlacement(placement) }
                })) {
                    ForEach(PanelPlacement.allCases, id: \.self) { placement in
                        Label(placement.shortcutTitle, systemImage: placement.shortcutSymbol).tag(placement)
                    }
                }.pickerStyle(.inline)
            }
            Menu("主题") {
                Picker("主题", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) {
                    Label("深色", systemImage: "moon").tag(PanelTheme.dark)
                    Label("浅色玻璃", systemImage: "sun.max").tag(PanelTheme.light)
                }.pickerStyle(.inline)
            }
            Divider()
            Button(action: settings) { Label("监控设置…", systemImage: "gearshape") }
            if compact {
                Divider()
                Button { store.setFloating(false) } label: { Label("关闭浮窗", systemImage: "xmark") }
                    .help("回到\(store.preferences.resolvedUnpinnedPlacement.shortcutTitle)")
            } else if let collapse {
                Divider()
                Button(action: collapse) {
                    Label(store.placement == .orb ? "收回圆环" : "收起面板", systemImage: "chevron.down")
                }
            }
        } label: {
            headerIcon("ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Palette.primary(store.theme.colorScheme))
        .fixedSize()
        .headerButtonHitArea()
        .accessibilityLabel("更多操作")
        .accessibilityValue(store.placement.shortcutTitle)
        .help("显示方式、主题与设置。当前：\(store.placement.shortcutTitle)")
    }

    private var separator: some View { Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: 0.5).padding(.horizontal, 16) }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: 0.5)
            HStack(spacing: 12) {
                UsageSummaryButton(store: store)
                if store.paused { Text("已暂停").font(.system(size: 13)) }
            }.foregroundStyle(Palette.secondary(store.theme.colorScheme)).font(.system(size: 13)).padding(.horizontal, 18).frame(height: PanelMetrics.footer)
        }
    }
}

private extension PanelPlacement {
    var shortcutTitle: String {
        switch self {
        case .top: "刘海模式"
        case .floating: "常驻浮窗"
        case .orb: "圆环"
        case .menuBar: "仅状态栏"
        }
    }
    var shortcutSymbol: String {
        switch self {
        case .top: "macbook"
        case .floating: "macwindow"
        case .orb: "circle"
        case .menuBar: "menubar.rectangle"
        }
    }
}

/// Keep one row identity across active/finished transitions, but observe its current data directly.
/// A lazy row must not retain a task snapshot captured by an older group-content closure.
private struct MonitorTaskRow: View {
    @ObservedObject var store: TaskStore
    let taskID: String
    let compact: Bool
    let animationsActive: Bool
    @Environment(\.compactMonitorTypography) private var windowCompactTypography
    private var compactTypography: Bool { compact || windowCompactTypography }

    var body: some View {
        if let task = store.graph.roots.first(where: { $0.id == taskID }) {
            let activity = store.graph.activity(for: task)
            let childCount = store.graph.children[taskID]?.count ?? 0
            Button { store.openTask(task) } label: {
                HStack(spacing: compact ? 11 : 14) {
                    ActivityIndicator(phase: activity.phase, small: compact, animationsActive: animationsActive)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(PanelFonts.readable(16, minimum: 14, scale: store.uiScale, weight: .medium, compact: compactTypography)).foregroundStyle(Palette.primary(store.theme.colorScheme)).lineLimit(1).truncationMode(.tail)
                        if !compact {
                            HStack(spacing: 5) {
                                Text(activity.detail).lineLimit(1)
                                if childCount > 0 { Text("· \(childCount) 个子任务").lineLimit(1) }
                            }.font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: compact ? 8 : 10) {
                        if activity.phase == .running {
                            if compact { TaskPhaseLabel(phase: .running) }
                            if let started = activity.startedAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let elapsed = max(0, Int(context.date.timeIntervalSince(started)))
                                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60)).monospacedDigit()
                                }.foregroundStyle(Palette.secondary(store.theme.colorScheme))
                            } else {
                                Text("--:--").monospacedDigit()
                                    .foregroundStyle(Palette.secondary(store.theme.colorScheme))
                                    .accessibilityLabel("运行计时待同步")
                                    .help("计时待同步：缺少本轮开始记录，暂时无法计算运行时间")
                            }
                        } else {
                            TaskPhaseLabel(phase: activity.phase)
                            if let elapsed = activity.waitingElapsedSeconds {
                                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                                    .monospacedDigit().foregroundStyle(Palette.secondary(store.theme.colorScheme))
                                    .help("本轮开始到进入待处理的时长，等待回答时暂停计时")
                            }
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                    }.font(PanelFonts.readable(13, scale: store.uiScale, compact: compactTypography)).fixedSize()
                }.padding(.horizontal, 16).frame(height: compact ? PanelMetrics.floatingRow : PanelMetrics.expandedRow).contentShape(Rectangle())
            }.buttonStyle(QuietRowStyle()).help(navigationHelp(for: task, activity: activity))
        }
    }

    private func navigationHelp(for task: CodexTask, activity: TaskActivity) -> String {
        guard activity.phase == .waiting else { return "\(task.title)\n\(activity.detail)\n点击回到 Codex" }
        let target = store.graph.navigationTarget(for: task)
        let waiting = activity.waitingStartedAt?.formatted(date: .abbreviated, time: .standard) ?? "时间缺失"
        let latest = activity.lastEventAt?.formatted(date: .abbreviated, time: .standard) ?? "时间缺失"
        return "\(target.title)\n进入待处理：\(waiting)\n最近活动记录：\(latest)\n尚未读到答复记录；已提交的答案可能仍在同步。\n点击打开待处理所在任务。Codex 暂不支持定位单条问题。"
    }
}

/// Resolve actual button bounds after scaling/layout so every other header point is draggable.
private struct HeaderButtonBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func headerButtonHitArea() -> some View {
        anchorPreference(key: HeaderButtonBounds.self, value: .bounds) { [$0] }
    }
}
