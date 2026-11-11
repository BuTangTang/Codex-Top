import SwiftUI
import CodexTopCore

/// 收起列表只生成一次时间值；显示时沿用原有每秒计划，不影响后台任务刷新。
struct MonitorElapsedTimelineSchedule: TimelineSchedule, Equatable {
    let active: Bool

    /// 重新显示时从框架传入的当前时间开始，隐藏时不再安排后续秒表更新。
    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        guard active else { return AnySequence(CollectionOfOne(startDate)) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 1).entries(from: startDate, mode: mode))
    }
}

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
    var contentVisible = true
    var collapse: (() -> Void)? = nil
    var pickTasks: () -> Void
    var settings: () -> Void
    var finishedChanged: () -> Void = {}
    var draggable = false
    var dragStarted: (CGPoint) -> Void = { _ in }
    var dragMoved: (CGPoint) -> Void = { _ in }
    var dragEnded: (CGPoint) -> Void = { _ in }
    /// 悬浮球面板传窗口控制器定下的卡片（和面板尺寸同一步换）；不传就直接跟着 store。
    var usageCardOverride: TaskOrigin?? = nil
    /// 悬浮球面板：列表固定按算好的高度，取整多出来的一点留在最底下。不这样的话，开关用量卡片时面板总高取整不同，
    /// 多出来的零头被列表吃掉，底栏和标题会跟着挪一两个像素（2026-11-11 用户录屏逐帧量出来：标题 +1、底栏 +2）。
    var fixedListHeight = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.compactMonitorTypography) private var windowCompactTypography
    @StateObject private var menuPresenter = MonitorMenuPresenter()
    @State private var retainsClosingContent = false
    private var compactTypography: Bool { compact || windowCompactTypography }

    /// 收起动画结束后卸载列表内容，避免隐藏列表继续排序和生成行视图。
    var body: some View {
        Group {
            if contentVisible || retainsClosingContent {
                if drawsSurface { PanelSurface { panelContent } }
                else { panelContent }
            }
        }
        .task(id: contentVisible) {
            // 展开立即生成内容；关闭保留短暂过渡，重新展开会取消释放任务。
            if contentVisible { retainsClosingContent = true }
            else {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                retainsClosingContent = false
                // 面板收回圆环后用量卡片也收起，下次打开不再带着它（2026-11-10 用户要求）。
                store.closeUsageCard()
            }
        }
        .foregroundStyle(Palette.primary(store.theme.colorScheme))
        .tint(Palette.accent)
        .environment(\.colorScheme, store.theme == .light ? .light : .dark)
        .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: store.theme)
    }

    /// 列表依据实际可用高度决定是否接收滚动，标题和底栏保持固定。
    private var panelContent: some View {
        VStack(spacing: 0) {
                header.layoutPriority(1)
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
                    GeometryReader { viewport in
                        let active = store.active
                        let fresh = store.freshTasks
                        let finished = showFinished ? store.finished : []
                        let contentHeight = CGFloat(active.count + fresh.count) * PanelMetrics.expandedRow
                            + (fresh.isEmpty ? 0 : PanelMetrics.freshHeader)
                            + CGFloat(finished.count) * PanelMetrics.finishedRow
                        ScrollView {
                            // Each section has uniform rows and an exact total height. Keep
                            // offscreen controls lazy without estimating a mixed-height list.
                            VStack(spacing: 0) {
                                if fresh.isEmpty {
                                    taskSection(active, rowHeight: PanelMetrics.expandedRow, separated: true)
                                } else {
                                    // D-91：需要你处理 → 刚完成 → 进行中。
                                    let attention = active.filter { [.waiting, .failed].contains(store.graph.activity(for: $0).phase) }
                                    taskSection(attention, rowHeight: PanelMetrics.expandedRow, separated: true)
                                    freshHeader(count: fresh.count)
                                    taskSection(fresh, rowHeight: PanelMetrics.expandedRow, separated: true, fresh: true)
                                    taskSection(active.filter { task in !attention.contains { $0.id == task.id } },
                                                rowHeight: PanelMetrics.expandedRow, separated: true)
                                }
                                if showFinished {
                                    taskSection(finished, rowHeight: PanelMetrics.finishedRow, separated: false)
                                }
                            }
                            // The panel owns disclosure/morph animation. Do not animate the
                            // insertion or removal of every offscreen history row as well.
                            .transaction { $0.animation = nil }
                        }
                        // 鼠标滚轮会让 macOS 用占宽度的旧式滚动条，出现时整列内容往左挪；列表不显示滚动条，宽度始终不变。
                        // 内容放得下时直接禁滚；允许一个物理像素的布局取整误差，实际超出仍能滚动。
                        .scrollDisabled(contentHeight <= viewport.size.height + hairline)
                        .scrollIndicators(.never).scrollBounceBehavior(.basedOnSize).frame(maxHeight: .infinity)
                    }
                    .frame(maxHeight: fixedListHeight ? store.listHeight(includesFinished: showFinished) : .infinity)
                }
                if let warning = store.panelWarning {
                    Label(warning, systemImage: "exclamationmark.circle").font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography)).foregroundStyle(Palette.primary(store.theme.colorScheme))
                        .lineLimit(3).padding(.horizontal, 20).padding(.vertical, 10)
                }
                if let notice = store.notice {
                    // D-86：提示独立成圆角浅底横幅，和任务行区分开。
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 13)).padding(.top, 1)
                        Text(notice).font(PanelFonts.readable(13, scale: store.uiScale, compact: compactTypography))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 20, height: 20) }.buttonStyle(QuietButtonStyle())
                    }
                    .foregroundStyle(Palette.secondary(store.theme.colorScheme))
                    .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 7)
                    .background(Palette.primary(store.theme.colorScheme).opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                footer.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                // 用量卡片在底栏下面，像从底栏下面拉出的抽屉（2026-11-11 用户看过对比后选“挪到底栏下面”）：
                // 打开时上面的任务和底栏位置都不动，外框往下长多少就露出多少卡片，不会再抖。
                usageCardSection.layoutPriority(1)
        }
        .frame(maxHeight: fixedListHeight ? .infinity : nil, alignment: .top)
        // The native panel/surface owns size changes. Inheriting its spring or
        // the disclosure transaction gives text and footer a second layout path.
        .animation(nil, value: showFinished)
        .animation(nil, value: animationsActive)
    }

    /// “刚完成”一段的段头：绿点 + 个数，右边“全部已看”。
    private func freshHeader(count: Int) -> some View {
        let green = Color(nsColor: LEDOrbView.toneColor(.done, dark: store.theme.colorScheme == .dark))
        return HStack(spacing: 6) {
            Circle().fill(green).frame(width: 6, height: 6)
            Text("刚完成 \(count)")
            Spacer(minLength: 4)
            Button("全部已看") { store.markAllFinishedSeen() }.buttonStyle(.plain).foregroundStyle(green)
                .help("这些任务收进“已结束”")
        }
        .font(PanelFonts.readable(12, scale: store.uiScale, weight: .semibold, compact: compactTypography))
        .foregroundStyle(Palette.secondary(store.theme.colorScheme))
        .padding(.horizontal, 16).frame(height: PanelMetrics.freshHeader)
    }

    private func taskSection(_ tasks: [CodexTask], rowHeight: CGFloat, separated: Bool, fresh: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(tasks.map(\.id), id: \.self) { taskID in
                MonitorTaskRow(store: store, taskID: taskID, compact: compact, animationsActive: animationsActive, fresh: fresh)
                    .frame(height: rowHeight)
                    .overlay(alignment: .bottom) {
                        // D-90：进行中的每行之间一道 1 像素细线（两块屏上都是整像素）。
                        if separated && taskID != tasks.last?.id {
                            Rectangle().fill(Palette.hairline(store.theme.colorScheme))
                                .frame(height: 1 / (displayScale * store.uiScale))
                                .padding(.horizontal, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }.frame(height: CGFloat(tasks.count) * rowHeight, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("监控任务").font(PanelFonts.readable(17, minimum: 15, scale: store.uiScale, weight: .semibold, compact: compactTypography)).lineLimit(1)
            if compact && store.demo { Text("演示").font(.system(size: 12)).foregroundStyle(Palette.secondary(store.theme.colorScheme)) }
            Spacer(minLength: 4)
            // D-90：原来的关注总数换成小点阵屏，和悬浮球一样显示 在跑｜等你｜失败。
            LEDMiniSummary(groups: store.ledGroups(), dark: store.theme.colorScheme == .dark)
                .help("\(store.runningCount) 个在跑 · \(store.statusSummary.waiting) 个等你回答 · \(store.statusSummary.failed) 个失败 · 共关注 \(store.selected.count) 个")
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
        Button {
            menuPresenter.present(store: store, compact: compact, settings: settings, collapse: collapse)
        } label: {
            headerIcon("ellipsis")
        }
        .background(MonitorMenuAnchor(presenter: menuPresenter).allowsHitTesting(false))
        .headerButtonHitArea()
        .accessibilityLabel("更多操作")
        .accessibilityValue(store.placement.shortcutTitle)
        .help("显示方式、主题与设置。当前：\(store.placement.shortcutTitle)")
    }

    /// 细线固定 1 个物理像素：0.5 点在 1 倍屏上会变成发虚的灰线。
    private var hairline: CGFloat { PanelMetrics.separatorHeight(displayScale: displayScale, uiScale: store.uiScale) }
    /// 卡片一打开就按全高放好，不自己做动画：面板换尺寸时内容一次按最终大小排好，只有外框慢慢长出来。
    @ViewBuilder private var usageCardSection: some View {
        if let origin = usageCardOverride ?? store.openUsageCard {
            VStack(spacing: 0) {
                Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: hairline)
                UsageCard(store: store, origin: origin)
            }
        }
    }
    private var separator: some View { Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: hairline).padding(.horizontal, 16) }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(height: hairline)
            HStack(spacing: 8) {
                if !store.finished.isEmpty {
                    Button {
                        showFinished.toggle()
                        finishedChanged()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showFinished ? 180 : 0))
                                .font(.system(size: 11, weight: .medium)).frame(width: 16)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showFinished)
                            Text("已结束 \(store.finished.count)")
                        }
                        .font(PanelFonts.readable(14, scale: store.uiScale, compact: compactTypography))
                        .fixedSize().frame(height: 30).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle())
                        .accessibilityLabel("已结束 \(store.finished.count) 个任务")
                        .accessibilityValue(showFinished ? "已展开" : "已折叠")
                        .help(showFinished ? "收起已结束任务" : "展开已结束任务")
                }
                if store.paused {
                    Image(systemName: "pause.circle").font(.system(size: 13))
                        .accessibilityLabel("任务刷新已暂停").help("任务刷新已暂停，额度仍独立更新")
                }
                UsageSummaryButton(store: store)
                if store.showsClaudeUsage {
                    Rectangle().fill(Palette.hairline(store.theme.colorScheme)).frame(width: hairline, height: 14)
                    ClaudeUsageButton(store: store)
                }
            }.foregroundStyle(Palette.secondary(store.theme.colorScheme)).padding(.leading, 16).padding(.trailing, 18).frame(height: PanelMetrics.footer)
        }
    }
}

extension PanelPlacement {
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

/// Observe current data directly: a lazy row must not retain a snapshot captured
/// by an older group-content closure when a task resumes or finishes.
private struct MonitorTaskRow: View {
    @ObservedObject var store: TaskStore
    let taskID: String
    let compact: Bool
    let animationsActive: Bool
    /// D-91：在“刚完成”一段里：绿色小灯、副标题写多久之前完成、右侧“完成”标签，行高和进行中一样。
    var fresh = false
    @Environment(\.compactMonitorTypography) private var windowCompactTypography
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var compactTypography: Bool { compact || windowCompactTypography }
    /// 1 倍屏上小字加重一档：macOS 不再做次像素抗锯齿，常规字重在 1 倍屏上发虚。
    private var crisp: Bool { displayScale < 2 }
    private var dark: Bool { store.theme.colorScheme == .dark }

    var body: some View {
        if let task = store.graph.roots.first(where: { $0.id == taskID }) {
            let activity = store.graph.activity(for: task)
            let childCount = store.graph.children[taskID]?.count ?? 0
            Button { store.openTask(task) } label: {
                // D-90：行首小 LED（和悬浮球同一套语言）；右侧等宽计时，等你／失败在计时下面加小标签。
                HStack(spacing: compact ? 10 : 12) {
                    // 进行中、刚完成的高行用和两行字一样高的竖条，已结束的矮行用半高。
                    let pipRows = fresh || !activity.phase.isFinished ? 8 : 4
                    LEDPip(phase: activity.phase, rows: pipRows, dark: dark, animating: animationsActive && !reduceMotion)
                        .frame(width: LEDPipView.width, height: LEDPipView.height(rows: pipRows))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(task.title).font(PanelFonts.readable(16, minimum: 14, scale: store.uiScale, weight: activity.phase.isFinished ? (crisp ? .medium : .regular) : .semibold, compact: compactTypography)).foregroundStyle(Palette.primary(store.theme.colorScheme)).lineLimit(1).truncationMode(.tail)
                            if store.panelShowsSourceMarks { SourceMark(origin: task.origin, scale: store.uiScale) }
                        }
                        if fresh, let finishedAt = store.freshFinished[taskID] {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                let minutes = Int(context.date.timeIntervalSince(finishedAt)) / 60
                                Text("本轮执行已结束 · \(minutes < 1 ? "刚刚" : "\(minutes) 分钟前")").lineLimit(1)
                            }
                            .font(PanelFonts.readable(14, scale: store.uiScale, weight: crisp ? .medium : .regular, compact: compactTypography))
                            .foregroundStyle(Palette.secondary(store.theme.colorScheme))
                        } else if !activity.phase.isFinished {
                            HStack(spacing: 5) {
                                Text(activity.detail).lineLimit(1)
                                if childCount > 0 { Text("· \(childCount) 个子任务").lineLimit(1) }
                                if activity.phase == .waiting, let since = activity.waitingStartedAt {
                                    TimelineView(.periodic(from: .now, by: 30)) { context in
                                        Text("· 已等 \(max(1, Int(context.date.timeIntervalSince(since)) / 60)) 分钟").lineLimit(1)
                                    }
                                }
                            }.font(PanelFonts.readable(14, scale: store.uiScale, weight: crisp ? .medium : .regular, compact: compactTypography)).foregroundStyle(Palette.secondary(store.theme.colorScheme))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if fresh { tag("完成", .done).fixedSize() } else { activityStatus(activity) }
                }
                .padding(.horizontal, 10).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }.buttonStyle(QuietRowStyle(cornerRadius: 10))
                .padding(.horizontal, 6).padding(.vertical, activity.phase.isFinished && !fresh ? 1 : 2)
                .frame(height: fresh ? PanelMetrics.expandedRow : PanelMetrics.rowHeight(for: activity.phase))
                .help(navigationHelp(for: task, activity: activity))
                .accessibilityIdentifier("monitor-task-\(taskID)")
                .contextMenu {
                    Button("打开任务") { store.openTask(task) }
                    if fresh { Button("标为已看") { store.markFinishedSeen(task.id) } }
                    Divider()
                    Button("移出监控") { store.removeFromMonitoring(task.id) }
                }
        }
    }

    /// 计时用等宽数字，开头的 0 调暗；运行与待处理的时间含义保持不变，只在列表显示时推进运行秒表。
    private func clock(_ seconds: Int) -> Text {
        let value = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        let dim = Palette.secondary(store.theme.colorScheme).opacity(0.55), main = Palette.primary(store.theme.colorScheme)
        guard value.hasPrefix("0") else { return Text(value).foregroundColor(main) }
        return Text("0").foregroundColor(dim) + Text(String(value.dropFirst())).foregroundColor(main)
    }

    private func tag(_ text: String, _ tone: LEDOrbLayout.Tone) -> some View {
        let tint = Color(nsColor: LEDOrbView.toneColor(tone, dark: dark))
        return Text(text).font(.system(size: 10 * max(1, store.uiScale), weight: .bold, design: .monospaced))
            .foregroundStyle(tint).padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }

    private func activityStatus(_ activity: TaskActivity) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            switch activity.phase {
            case .running:
                if let started = activity.startedAt {
                    TimelineView(MonitorElapsedTimelineSchedule(active: animationsActive)) { context in
                        clock(max(0, Int(context.date.timeIntervalSince(started))))
                    }
                } else {
                    Text("--:--").foregroundStyle(Palette.secondary(store.theme.colorScheme))
                        .accessibilityLabel("运行计时待同步")
                        .help("计时待同步：缺少本轮开始记录，暂时无法计算运行时间")
                }
            case .waiting:
                if let elapsed = activity.waitingElapsedSeconds {
                    clock(elapsed).help("本轮开始到进入待处理的时长，等待回答时暂停计时")
                }
                tag("等你", .waiting)
            case .failed:
                tag("失败", .failed)
            default:
                TaskPhaseLabel(phase: activity.phase)
            }
        }
        .font(PanelFonts.readable(13, scale: store.uiScale, weight: .semibold, compact: compactTypography)).monospaced()
        .fixedSize()
    }

    private func navigationHelp(for task: CodexTask, activity: TaskActivity) -> String {
        let children = store.graph.children[task.id]?.count ?? 0
        let childDetail = children > 0 ? "\n\(children) 个子任务" : ""
        let source = task.origin.displayName
        guard activity.phase == .waiting else { return "\(task.title)\n\(activity.detail)\(childDetail)\n点击回到 \(source)" }
        let target = store.graph.navigationTarget(for: task)
        let waiting = activity.waitingStartedAt?.formatted(date: .abbreviated, time: .standard) ?? "时间缺失"
        let latest = activity.lastEventAt?.formatted(date: .abbreviated, time: .standard) ?? "时间缺失"
        return "\(target.title)\n进入待处理：\(waiting)\n最近活动记录：\(latest)\n尚未读到答复记录；已提交的答案可能仍在同步。\n点击打开待处理所在任务。\(source) 暂不支持定位单条问题。"
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
