import SwiftUI
import CodexTopCore

@MainActor final class OrbMorphState: ObservableObject {
    @Published var expanded = false
    @Published var hovered = false
    @Published var surfaceFrame = CGRect(x: 0, y: 0, width: 44, height: 44)
    @Published var expandedSize = CGSize(width: 410, height: 340)
}

struct FloatingPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var orbState: OrbMorphState
    @ObservedObject var monitorState: MonitorPanelState
    var pickTasks: () -> Void
    var settings: () -> Void
    var openTasks: () -> Void
    var closeTasks: () -> Void
    var finishedChanged: () -> Void
    var dragStarted: () -> Void
    var dragMoved: () -> Void
    var dragEnded: () -> Void
    var body: some View {
        if store.placement == .orb {
            OrbPanelView(store: store, state: orbState, showFinished: $monitorState.expandedFinished, openTasks: openTasks, closeTasks: closeTasks,
                         pickTasks: pickTasks, settings: settings, finishedChanged: finishedChanged,
                         dragStarted: dragStarted, dragMoved: dragMoved, dragEnded: dragEnded)
        } else {
            AnimatedPanel(presentation: presentation, anchor: .center) {
                ScaledPanel(scale: store.uiScale) {
                    MonitorView(store: store, compact: true, showFinished: $monitorState.floatingFinished, pickTasks: pickTasks, settings: settings,
                                finishedChanged: finishedChanged, dragStarted: dragStarted, dragMoved: dragMoved, dragEnded: dragEnded)
                }
            }
        }
    }
}

/// The ring and list occupy the same NSPanel and the same interpolated surface.
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
    var dragStarted: () -> Void
    var dragMoved: () -> Void
    var dragEnded: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            GlassFill()
            Color.black.opacity(state.expanded ? 0 : 1)
            MonitorView(store: store, compact: false, showFinished: $showFinished, drawsSurface: false, collapse: closeTasks,
                        pickTasks: pickTasks, settings: settings, finishedChanged: finishedChanged)
                .frame(width: state.expandedSize.width / store.uiScale, height: state.expandedSize.height / store.uiScale)
                .scaleEffect(store.uiScale * (state.expanded || reduceMotion ? 1 : 0.72))
                .frame(width: state.expandedSize.width, height: state.expandedSize.height)
                .opacity(state.expanded ? 1 : 0)
                .animation(reduceMotion ? nil : state.expanded ? .easeOut(duration: 0.16).delay(0.07) : .easeOut(duration: 0.09), value: state.expanded)
                .allowsHitTesting(state.expanded)
                .accessibilityHidden(!state.expanded)
            StatusRing(store: store, hovered: state.hovered, visible: !state.expanded)
                .frame(width: 44, height: 44)
                .overlay {
                    WindowDragHandle(started: dragStarted, moved: dragMoved, ended: dragEnded, showsGrip: false)
                }
                .opacity(state.expanded ? 0 : 1)
                .animation(.easeOut(duration: 0.10), value: state.expanded)
                .allowsHitTesting(!state.expanded)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Codex Top 圆环，\(store.statusSummary.phase.label)，\(store.runningCount) 个运行中，\(store.attentionCount) 个需要处理")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openTasks() }
                .accessibilityHidden(state.expanded)
                .help(store.dockingHint ? "松手收进状态栏" : "\(store.statusSummary.phase.label) · \(store.runningCount) 个运行中 · \(store.attentionCount) 个需要处理\n悬停或点击展开，拖动移动")
        }
        .frame(width: state.surfaceFrame.width, height: state.surfaceFrame.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(store.dockingHint ? Palette.accent : .clear, lineWidth: 1))
        .position(x: state.surfaceFrame.midX, y: state.surfaceFrame.midY)
        .environment(\.colorScheme, store.theme == .light ? .light : .dark)
        .onExitCommand(perform: closeTasks)
    }
}

/// One thin ring. Attention takes priority; the tooltip still exposes simultaneous counts.
private struct StatusRing: View {
    @ObservedObject var store: TaskStore
    var hovered: Bool
    var visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completion: CGFloat = 1
    @State private var completionFlashing = false
    @State private var handledCompletionSequence = 0
    private var currentPhase: TaskPhase { store.statusSummary.phase }
    private var phase: TaskPhase { completionFlashing && store.attentionCount == 0 ? .completed : currentPhase }
    private var animationTrigger: String { "\(currentPhase.rawValue)-\(store.completionSequence)" }
    private var animated: Bool { [.running, .waiting, .failed].contains(phase) && !reduceMotion && visible }
    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = 0.68 + 0.32 * (sin(time * .pi * 1.6) + 1) / 2
            Circle()
                .trim(from: phase == .running ? 0.08 : 0, to: phase == .running ? 0.78 : phase == .completed ? completion : 1)
                .stroke(phase.tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(phase == .running && !reduceMotion ? time * 300 : -90))
                .opacity([.waiting, .failed].contains(phase) && !reduceMotion ? breath : phase == .idle ? 0.55 : 1)
                .padding(7)
        }
        .scaleEffect(hovered && !reduceMotion ? 1.08 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.14), value: hovered)
        .onAppear { handledCompletionSequence = store.completionSequence }
        .task(id: animationTrigger) {
            let flash = store.completionSequence > handledCompletionSequence && currentPhase == .running && !reduceMotion
            handledCompletionSequence = store.completionSequence
            completionFlashing = flash
            if (currentPhase == .completed || flash) && !reduceMotion {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { completion = 0 }
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.45)) { completion = 1 }
                if flash {
                    try? await Task.sleep(for: .seconds(1.1))
                    guard !Task.isCancelled else { return }
                    completionFlashing = false
                }
            } else { completion = 1 }
        }
    }
}
