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
    var collapse: (() -> Void)? = nil
    var pickTasks: () -> Void
    var settings: () -> Void
    var finishedChanged: () -> Void = {}
    var dragStarted: () -> Void = {}
    var dragMoved: () -> Void = {}
    var dragEnded: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleTaskIDs: [String] {
        (store.active + (showFinished ? store.finished : [])).map(\.id)
    }

    var body: some View {
        Group {
            if drawsSurface { PanelSurface { panelContent } }
            else { panelContent }
        }
        .foregroundStyle(Palette.primary)
        .tint(Palette.accent)
        .environment(\.colorScheme, store.theme == .light ? .light : .dark)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
                header
                separator
                if store.loading {
                    ProgressView("正在读取任务…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.selected.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.stack").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.secondary)
                        Text("选择你想关注的任务").font(.system(size: 16, weight: .medium))
                        Text("新建并运行的任务会自动加入").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        Button("选择任务", action: pickTasks).controlSize(.large)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        VStack(spacing: 0) {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(visibleTaskIDs, id: \.self) { taskID in
                                        VStack(spacing: 0) {
                                            MonitorTaskRow(store: store, taskID: taskID, compact: compact)
                                            separator
                                        }.id(taskID)
                                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                                    }
                                }
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: visibleTaskIDs)
                            }.scrollIndicators(.automatic).frame(maxHeight: .infinity)
                            if !store.finished.isEmpty {
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { showFinished.toggle() }
                                    finishedChanged()
                                    if showFinished, let first = store.finished.first {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { proxy.scrollTo(first.id, anchor: .top) }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "chevron.down").rotationEffect(.degrees(showFinished ? 180 : 0))
                                            .font(.system(size: 11, weight: .medium)).frame(width: 24)
                                        Text("已结束 \(store.finished.count)").font(.system(size: 13))
                                        Spacer()
                                    }.foregroundStyle(Palette.secondary).padding(.horizontal, 16).frame(height: PanelMetrics.disclosure)
                                }.buttonStyle(QuietRowStyle())
                            }
                        }
                    }
                }
                if let warning = store.sourceWarning {
                    Label(warning, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(TaskPhase.waiting.tint)
                        .lineLimit(3).padding(.horizontal, 20).padding(.vertical, 10)
                }
                if let notice = store.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Text(notice).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        Spacer(minLength: 0)
                        Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 22, height: 22) }.buttonStyle(QuietButtonStyle())
                    }.padding(.horizontal, 20).padding(.vertical, 10)
                }
                if !compact { footer }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if compact {
                WindowDragHandle(started: dragStarted, moved: dragMoved, ended: dragEnded)
                    .frame(width: 16, height: 30)
                    .help("拖动浮窗；靠近顶部松手收进状态栏")
            }
            Text(store.dockingHint && compact ? "松手收进状态栏" : "监控任务").font(PanelFonts.header)
            Text(store.dockingHint && compact ? "" : "\(store.selected.count)").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.selected.count)
            if compact && store.demo { Text("演示").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
            Spacer(minLength: 4)
            if compact {
                Button { store.setTheme(store.theme == .dark ? .light : .dark) } label: {
                    Image(systemName: store.theme == .dark ? "sun.max" : "moon").font(.system(size: 14)).foregroundStyle(Palette.secondary).frame(width: 24, height: 30)
                }.accessibilityLabel(store.theme == .dark ? "切换浅色玻璃" : "切换深色玻璃")
            }
            if !compact {
                Button(action: pickTasks) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                        Text("选择任务").font(PanelFonts.label)
                    }.foregroundStyle(Palette.secondary).padding(.horizontal, 10).frame(height: 30)
                        .background(Palette.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                }.help("搜索和选择监控任务").accessibilityLabel("选择任务")
            }
            Button { store.setFloating(!store.preferences.floating) } label: {
                Image(systemName: store.preferences.floating ? "pin.fill" : "pin")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(store.preferences.floating ? Palette.accent : Palette.secondary).frame(width: 28, height: 30)
            }.help(compact ? "收回顶部" : "悬浮置顶").accessibilityLabel(compact ? "收回顶部" : "悬浮置顶")
            if let collapse {
                Button(action: collapse) {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .medium)).frame(width: 24, height: 30)
                }.accessibilityLabel("收回圆环").help("缩回原来的圆环位置")
            }
            if compact {
                Button { store.setFloating(false) } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.secondary).frame(width: 25, height: 30)
                }.help("关闭浮窗，保留顶部监控").accessibilityLabel("关闭浮窗")
            }
        }.buttonStyle(QuietButtonStyle()).padding(.horizontal, 16)
            .frame(height: compact ? PanelMetrics.floatingHeader : PanelMetrics.expandedHeader)
            .contextMenu { Button("选择任务", action: pickTasks); Button("监控设置", action: settings) }
    }

    private var separator: some View { Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.horizontal, 16) }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 0.5)
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 14))
                if let quota = store.quota {
                    HStack(spacing: 10) {
                        if let five = quota.fiveHour { Text("5h 剩余 \(five.remainingPercent)%") }
                        if quota.fiveHour != nil && quota.weekly != nil { Text("·") }
                        if let week = quota.weekly { Text("本周剩余 \(week.remainingPercent)%") }
                    }.help("来自日志，更新于 \(quota.observedAt.formatted(date: .abbreviated, time: .standard))")
                    if Date().timeIntervalSince(quota.observedAt) > 300 { Text("历史值").font(.system(size: 11)).foregroundStyle(TaskPhase.waiting.tint) }
                } else {
                    Text(store.demo ? "演示模式 · 额度暂无数据" : "额度暂无数据").help("等待 Codex 写入用量记录")
                }
                Spacer(minLength: 0)
                if store.paused { Text("已暂停").font(.system(size: 12)) }
                Button { store.setTheme(store.theme == .dark ? .light : .dark) } label: {
                    Image(systemName: store.theme == .dark ? "sun.max" : "moon").font(.system(size: 15)).frame(width: 26, height: 30)
                }.buttonStyle(QuietButtonStyle()).accessibilityLabel(store.theme == .dark ? "切换浅色玻璃" : "切换深色玻璃")
                Button(action: settings) { Image(systemName: "gearshape.fill").font(.system(size: 15)).frame(width: 28, height: 30) }
                    .buttonStyle(QuietButtonStyle()).help("监控设置").accessibilityLabel("监控设置")
            }.foregroundStyle(Palette.secondary).font(.system(size: 12)).padding(.horizontal, 18).frame(height: PanelMetrics.footer)
        }
    }
}

/// Keep one row identity across active/finished transitions, but observe its current data directly.
/// A lazy row must not retain a task snapshot captured by an older group-content closure.
private struct MonitorTaskRow: View {
    @ObservedObject var store: TaskStore
    let taskID: String
    let compact: Bool

    var body: some View {
        if let task = store.graph.roots.first(where: { $0.id == taskID }) {
            let activity = store.graph.activity(for: task)
            let childCount = store.graph.children[taskID]?.count ?? 0
            Button { store.openTask(task) } label: {
                HStack(spacing: compact ? 11 : 14) {
                    ActivityIndicator(phase: activity.phase, small: compact)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(PanelFonts.task).foregroundStyle(Palette.primary).lineLimit(1)
                        if !compact {
                            HStack(spacing: 5) {
                                Text(activity.detail).lineLimit(1)
                                if childCount > 0 { Text("· \(childCount) 个子任务").lineLimit(1) }
                            }.font(PanelFonts.detail).foregroundStyle(Palette.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: compact ? 8 : 10) {
                        if activity.phase == .running {
                            if compact { Text("运行中").foregroundStyle(activity.phase.tint) }
                            if let started = activity.startedAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let elapsed = max(0, Int(context.date.timeIntervalSince(started)))
                                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60)).monospacedDigit()
                                }.foregroundStyle(Palette.secondary)
                            }
                        } else { Text(activity.phase.label).foregroundStyle(activity.phase.tint) }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                    }.font(.system(size: 12)).fixedSize()
                }.padding(.horizontal, 16).frame(height: compact ? PanelMetrics.floatingRow : PanelMetrics.expandedRow).contentShape(Rectangle())
            }.buttonStyle(QuietRowStyle()).help("\(task.title)\n\(activity.detail)\n点击回到 Codex")
        }
    }
}
