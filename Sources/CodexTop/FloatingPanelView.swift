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
    @State private var attentionScale: CGFloat = 1
    private var shouldBreathe: Bool { store.attentionCount > 0 && !state.expanded && !reduceMotion }
    var body: some View {
        ZStack {
            GlassFill()
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
                .help("\(store.statusSummary.phase.label) · \(store.runningCount) 个运行中 · \(store.attentionCount) 个需要处理\n点击展开，拖动移动，右键打开菜单")
        }
        .frame(width: state.surfaceFrame.width, height: state.surfaceFrame.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .circular))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .circular)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                .opacity(store.theme == .light && !state.expanded ? 1 : 0)
                .animation(.easeOut(duration: 0.10), value: state.expanded)
                .allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .circular).stroke(store.dockingHint ? Palette.accent : .clear, lineWidth: 1))
        .scaleEffect(state.expanded || reduceMotion ? 1 : attentionScale)
        .position(x: state.surfaceFrame.midX, y: state.surfaceFrame.midY)
        .environment(\.colorScheme, store.theme == .light ? .light : .dark)
        .onExitCommand(perform: closeTasks)
        .task(id: shouldBreathe) {
            guard shouldBreathe else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { attentionScale = 1 }
                return
            }
            // Animate the clipped surface only; the native 44pt window stays fixed.
            // Finite half-cycles stop when state changes, without repeatForever residue.
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.9)) { attentionScale = 0.94 }
                do { try await Task.sleep(for: .seconds(0.9)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.9)) { attentionScale = 1 }
                do { try await Task.sleep(for: .seconds(0.9)) } catch { return }
            }
        }
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
    private var animated: Bool { phase == .running && !reduceMotion && visible }
    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: phase == .running ? 0.08 : 0, to: phase == .running ? 0.78 : phase == .completed ? completion : 1)
                .stroke(phase.tint(store.theme.colorScheme), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: store.theme)
                .rotationEffect(.degrees(phase == .running && !reduceMotion ? time * 300 : -90))
                .opacity(phase == .idle ? 0.55 : 1)
                .padding(7)
        }
        .overlay {
            Group {
                if currentPhase == .completed && store.runningCount == 0 {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
                } else {
                    Text(store.runningCount > 99 ? "99+" : String(store.runningCount))
                        .font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.runningCount)
                        .lineLimit(1).minimumScaleFactor(0.65)
                }
            }
            .foregroundStyle(currentPhase == .completed ? phase.tint(store.theme.colorScheme) : Palette.primary(store.theme.colorScheme))
            .frame(width: 24, height: 24)
            .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: store.theme)
            .accessibilityHidden(true)
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
