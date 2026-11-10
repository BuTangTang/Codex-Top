import SwiftUI
import CodexTopCore


@MainActor final class OrbMorphState: ObservableObject {
    @Published var expanded = false
    @Published var hovered = false
    @Published var expansionDirection: OrbExpansionDirection = .down
    @Published var surfaceFrame = CGRect(x: 0, y: 0, width: 44, height: 44)
    @Published var expandedSize = CGSize(width: 410, height: 340)
    /// 收起后的面板比 44 宽时，靠近屏幕右边缘就向左长。
    @Published var capsuleGrowsLeft = false
}

struct FloatingPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var resizeState: FloatingResizeState
    @ObservedObject var orbState: OrbMorphState
    @ObservedObject var monitorState: MonitorPanelState
    var pickTasks: () -> Void
    var settings: () -> Void
    var openTasks: () -> Void
    var closeTasks: () -> Void
    var finishedChanged: () -> Void
    var dragStarted: (CGPoint) -> Void
    var dragMoved: (CGPoint) -> Void
    var dragEnded: (CGPoint) -> Void
    var body: some View {
        if (presentation.placement ?? store.placement) == .orb {
            OrbPanelView(store: store, state: orbState, showFinished: $monitorState.expandedFinished, openTasks: openTasks, closeTasks: closeTasks,
                         pickTasks: pickTasks, settings: settings, finishedChanged: finishedChanged,
                         dragStarted: dragStarted, dragMoved: dragMoved, dragEnded: dragEnded)
        } else {
            MonitorView(store: store, compact: true, showFinished: $monitorState.floatingFinished, pickTasks: pickTasks, settings: settings,
                        finishedChanged: finishedChanged, draggable: true, dragStarted: dragStarted, dragMoved: dragMoved, dragEnded: dragEnded)
                .modifier(FloatingViewport(size: resizeState.size, scale: store.uiScale))
        }
    }
}

/// Both ring appearances and the list share one NSPanel and interpolated surface.
/// At 44pt, a 22pt corner radius is a circle; the expanding surface becomes a rounded panel.
private struct OrbPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: OrbMorphState
    @Binding var showFinished: Bool
    var openTasks: () -> Void
    var closeTasks: () -> Void
    var pickTasks: () -> Void
    var settings: () -> Void
    var finishedChanged: () -> Void
    var dragStarted: (CGPoint) -> Void
    var dragMoved: (CGPoint) -> Void
    var dragEnded: (CGPoint) -> Void
    @Environment(\.displayScale) private var displayScale
    private var usesTwinArc: Bool { store.orbAppearance == .twinArc }
    private var statusLabel: String { usesTwinArc ? store.orbStatusLabel : store.statusSummary.phase.label }
    private var statusDetail: String {
        if usesTwinArc && store.orbPhase == .unknown { return statusLabel }
        return "\(statusLabel) · \(store.runningCount) 个运行中 · \(store.attentionCount) 个需要处理"
    }
    /// LED 面板收起时是圆角 12 的方块；展开和双弧外观仍用 22（44pt 时就是正圆）。
    private var surfaceRadius: CGFloat { usesTwinArc || state.expanded ? 22 : 12 }
    private var contentAlignment: Alignment { state.expansionDirection == .up ? .bottom : .top }
    /// 圆环与面板共享外壳，收起后卸载任务列表以减少隐藏计算。
    var body: some View {
        ZStack(alignment: contentAlignment) {
            GlassFill()
            MonitorView(store: store, compact: false, showFinished: $showFinished, drawsSurface: false, animationsActive: state.expanded, contentVisible: state.expanded, collapse: closeTasks,
                        pickTasks: pickTasks, settings: settings, finishedChanged: finishedChanged,
                        draggable: true, dragStarted: dragStarted, dragMoved: dragMoved, dragEnded: dragEnded)
                .frame(width: state.expandedSize.width / store.uiScale, height: state.expandedSize.height / store.uiScale)
                // Keep text at its final scale while the enclosing surface reveals it.
                // A second center-based zoom makes the fixed header drift at opening.
                .scaleEffect(store.uiScale)
                .frame(width: state.expandedSize.width, height: state.expandedSize.height)
                .modifier(OrbRevealOpacity(progress: state.expanded ? 1 : 0, layer: .content))
                .allowsHitTesting(state.expanded)
                .accessibilityHidden(!state.expanded)
            Group {
                if usesTwinArc {
                    TwinArcOrb(phase: store.orbPhase, runningCount: store.paused || store.loading ? 0 : store.runningCount,
                               visible: !state.expanded, hovered: state.hovered)
                        .frame(width: 44, height: 44)
                } else {
                    LEDOrbContent(store: store, hovered: state.hovered, visible: !state.expanded)
                }
            }
                // 收起时贴着起点那一侧，面板随外壳变宽展开；展开时居中淡出。
                .frame(width: state.expanded ? nil : state.surfaceFrame.width, height: 44,
                       alignment: state.capsuleGrowsLeft ? .trailing : .leading)
                // LED 面板变窄的过渡里，外壳比点阵宽的那一截也铺面板底色。
                .background { if !usesTwinArc { LEDOrbView.panelColor(dark: store.theme.colorScheme == .dark) } }
                .overlay {
                    WindowDragHandle(started: dragStarted, moved: dragMoved, ended: dragEnded, enabled: !state.expanded)
                }
                .modifier(OrbRevealOpacity(progress: state.expanded ? 1 : 0, layer: .ring))
                .allowsHitTesting(!state.expanded)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Codex Top \(usesTwinArc ? "渐隐双弧" : "圆环")，\(statusDetail)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openTasks() }
                .accessibilityHidden(state.expanded)
                .help("\(statusDetail)\n点击展开，拖动移动，右键打开菜单")
        }
        .frame(width: state.surfaceFrame.width, height: state.surfaceFrame.height,
               alignment: contentAlignment)
        .clipShape(RoundedRectangle(cornerRadius: surfaceRadius, style: .circular))
        .overlay {
            RoundedRectangle(cornerRadius: surfaceRadius, style: .circular)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1 / displayScale)
                .opacity(store.theme == .light && (!usesTwinArc || state.expanded) ? 1 : 0)
                .allowsHitTesting(false)
        }
        .position(x: state.surfaceFrame.midX, y: state.surfaceFrame.midY)
        .environment(\.colorScheme, store.theme == .light ? .light : .dark)
        .onExitCommand(perform: closeTasks)
    }
}

/// Derive visibility from the same spring as the surface, rather than starting
/// independent delayed fades. Reversing the spring also reverses the reveal.
private struct OrbRevealOpacity: AnimatableModifier {
    enum Layer { case content, ring }
    var progress: Double
    let layer: Layer
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let alpha: Double
        switch layer {
        case .content: alpha = smoothstep((progress - 0.12) / 0.38)
        case .ring: alpha = 1 - smoothstep(progress / 0.16)
        }
        return content.opacity(alpha)
    }
    private func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

/// D-89 经典圆环收起后的样子：LED 点阵。白色是在跑的个数、琥珀等你回答、红失败；四周一圈暗灯，有任务在跑时 5 颗蓝灯顺时针绕圈。
private struct LEDOrbContent: View {
    @ObservedObject var store: TaskStore
    var hovered: Bool
    var visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 全部完成 5 分钟还没有新任务，就从 OK 换成休眠 Zz（D-91）。
    @State private var sleeping = false
    static let sleepAfter: Duration = .seconds(300)
    private var allDone: Bool { store.ledGroups().first?.tone == .done && store.ledGroups().count == 1 }
    private var ring: LEDOrbView.RingMode {
        if allDone { return .done }
        return store.ledGroups().first?.tone == .running ? .running : .idle
    }
    var body: some View {
        let groups = store.ledGroups(sleeping: sleeping)
        LEDOrb(groups: groups, ring: ring, completions: store.completionSequence, dark: store.theme.colorScheme == .dark, hovered: hovered,
               animating: visible && !reduceMotion)
            .frame(width: LEDOrbLayout.layout(groups).width, height: LEDOrbLayout.height)
            .task(id: allDone) {
                sleeping = false
                guard allDone else { return }
                try? await Task.sleep(for: Self.sleepAfter)
                guard !Task.isCancelled else { return }
                sleeping = true
            }
    }
}

extension TaskStore {
    /// 圆球和窗口宽度共用同一份分组，保证画出来的宽度和窗口一致（OK 和 Zz 一样宽）。
    /// 绿色个数是“刚完成”一段还剩几个，悬浮球和面板标题栏一致。
    func ledGroups(sleeping: Bool = false) -> [LEDOrbLayout.Group] {
        LEDOrbLayout.groups(running: runningCount, waiting: statusSummary.waiting, failed: statusSummary.failed,
                            fresh: freshFinished.count,
                            allDone: statusSummary.phase == .completed && runningCount == 0, sleeping: sleeping,
                            unknown: paused || loading || statusSummary.phase == .unknown)
    }
}
