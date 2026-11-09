import SwiftUI
import CodexTopCore


@MainActor final class OrbMorphState: ObservableObject {
    @Published var expanded = false
    @Published var hovered = false
    @Published var expansionDirection: OrbExpansionDirection = .down
    @Published var surfaceFrame = CGRect(x: 0, y: 0, width: 44, height: 44)
    @Published var expandedSize = CGSize(width: 410, height: 340)
    /// D-88：收起成胶囊时琥珀段在圆球左边（靠近屏幕右边缘时）。
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
    private var usesTwinArc: Bool { store.orbAppearance == .twinArc }
    private var statusLabel: String { usesTwinArc ? store.orbStatusLabel : store.statusSummary.phase.label }
    private var statusDetail: String {
        if usesTwinArc && store.orbPhase == .unknown { return statusLabel }
        return "\(statusLabel) · \(store.runningCount) 个运行中 · \(store.attentionCount) 个需要处理"
    }
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
                    CapsuleOrb(store: store, growsLeft: state.capsuleGrowsLeft, hovered: state.hovered, visible: !state.expanded)
                }
            }
                // 收起时贴着圆球那一侧，胶囊随外壳变宽从圆球旁长出；展开时居中淡出。
                .frame(width: state.expanded ? nil : state.surfaceFrame.width, height: 44,
                       alignment: state.capsuleGrowsLeft ? .trailing : .leading)
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
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .circular))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .circular)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
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

/// D-88 经典圆环收起后的样子：一颗圆球（转圈刻度 + 在跑的个数），有任务等你时旁边长出胶囊段。
/// 一种东西只表达一件事：刻度在转 = 有任务在跑；白色数字 = 在跑的个数；
/// 琥珀段 = 等你回答的个数，红段 = 失败的个数，两种都有就两段都弹出来（琥珀挨着圆球，红在最外头）。
private struct CapsuleOrb: View {
    @ObservedObject var store: TaskStore
    let growsLeft: Bool
    var hovered: Bool
    var visible: Bool
    private struct Segment { let count: Int; let color: Color; let fillStart: CGFloat; let labelStart: CGFloat; let end: CGFloat }
    /// 从圆球那头往外排：第一段的底色从圆心铺起，免得圆球边上露出底板；数字放在圆球外面那一截里。
    private var segments: [Segment] {
        guard !store.paused, !store.loading else { return [] }
        var x: CGFloat = 44, result: [Segment] = []
        // 段落颜色固定用深色主题的亮琥珀／亮红，配深色字，浅色主题下也清楚。
        for (count, phase) in [(store.statusSummary.waiting, TaskPhase.waiting), (store.statusSummary.failed, .failed)] where count > 0 {
            let width = WindowGeometry.orbCapsuleSegment(count: count)
            let first = result.isEmpty
            result.append(Segment(count: count, color: phase.tint(.dark), fillStart: first ? 22 : x, labelStart: first ? 38 : x, end: x + width))
            x += width
        }
        return result
    }
    var body: some View {
        let segments = self.segments
        let width = segments.last?.end ?? 44
        // 向左长时整体镜像位置（文字不镜像）。
        let place = { (start: CGFloat, end: CGFloat) -> CGFloat in growsLeft ? width - end : start }
        ZStack(alignment: .leading) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segment.color.frame(width: segment.end - segment.fillStart).offset(x: place(segment.fillStart, segment.end))
            }
            if segments.count > 1 {
                // 两段之间一道深色细缝，琥珀和红不糊在一起。
                Color(.sRGB, red: 0x15 / 255, green: 0x18 / 255, blue: 0x1D / 255)
                    .frame(width: 1.5).offset(x: place(segments[1].fillStart - 0.75, segments[1].fillStart + 0.75))
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Text(segment.count > 99 ? "99+" : String(segment.count))
                    .font(.system(size: 18, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(Color(.sRGB, red: 0x1B / 255, green: 0x1E / 255, blue: 0x24 / 255))
                    .frame(width: segment.end - segment.labelStart)
                    .offset(x: place(segment.labelStart, segment.end))
            }
            TickOrb(store: store, hovered: hovered, visible: visible)
                .frame(width: 44, height: 44)
                .offset(x: place(0, 44))
        }
        .frame(width: width, height: 44, alignment: .leading)
    }
}

/// 圆球本体：12 根刻度顺时针转圈表示有任务在跑，中间只写在跑的个数。
private struct TickOrb: View {
    @ObservedObject var store: TaskStore
    var hovered: Bool
    var visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionFlashing = false
    @State private var handledCompletionSequence = 0
    private var scheme: ColorScheme { store.theme.colorScheme }
    private var currentPhase: TaskPhase { store.statusSummary.phase }
    private var unknown: Bool { store.paused || store.loading || currentPhase == .unknown }
    private var allDone: Bool { !unknown && currentPhase == .completed && store.runningCount == 0 }
    private var running: Int { unknown ? 0 : store.runningCount }
    private var animationTrigger: String { "\(currentPhase.rawValue)-\(store.completionSequence)" }
    var body: some View {
        ZStack {
            if scheme == .dark {
                Circle().fill(Color(.sRGB, red: hovered ? 0x1E / 255 : 0x15 / 255, green: hovered ? 0x22 / 255 : 0x18 / 255,
                                    blue: hovered ? 0x29 / 255 : 0x1D / 255))
            }
            TickSpinner(color: tickColor, spinning: running > 0 && !allDone && !completionFlashing && visible && !reduceMotion,
                        gradient: running > 0 && !completionFlashing, opacity: allDone || completionFlashing ? 0.9 : running > 0 ? 1 : 0.16)
            Group {
                if allDone {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(TaskPhase.completed.tint(scheme))
                } else {
                    Text(unknown ? "?" : running > 99 ? "99+" : String(running))
                        .font(.system(size: 17, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(running > 0 ? Palette.primary(scheme) : Palette.secondary(scheme))
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: running)
                        .lineLimit(1).minimumScaleFactor(0.65)
                }
            }
            .frame(width: 26, height: 24)
            .accessibilityHidden(true)
        }
        .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: store.theme)
        .onAppear { handledCompletionSequence = store.completionSequence }
        .task(id: animationTrigger) {
            // 有任务刚做完而其他任务还在跑时，刻度短暂变绿再接着转。
            let flash = store.completionSequence > handledCompletionSequence && currentPhase == .running && !reduceMotion
            handledCompletionSequence = store.completionSequence
            completionFlashing = flash
            guard flash else { return }
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            completionFlashing = false
        }
    }
    private var tickColor: Color {
        if allDone || completionFlashing { return TaskPhase.completed.tint(scheme) }
        return running > 0 ? TaskPhase.running.tint(scheme) : Palette.primary(scheme)
    }
}
