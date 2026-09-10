import SwiftUI
import CodexTopCore

struct FloatingPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var presentation: PanelPresentation
    var pickTasks: () -> Void
    var settings: () -> Void
    var openTasks: () -> Void
    var finishedChanged: (Bool) -> Void
    var dragStarted: () -> Void
    var dragMoved: () -> Void
    var dragEnded: () -> Void
    var body: some View {
        if store.placement == .orb {
            OrbView(store: store, openTasks: openTasks, dragStarted: dragStarted, dragMoved: dragMoved, dragEnded: dragEnded)
        } else {
            AnimatedPanel(presentation: presentation, anchor: .center) {
                ScaledPanel(scale: store.uiScale) {
                    MonitorView(store: store, compact: true, pickTasks: pickTasks, settings: settings,
                                finishedChanged: finishedChanged, dragStarted: dragStarted, dragMoved: dragMoved, dragEnded: dragEnded)
                }
            }
        }
    }
}

private struct OrbView: View {
    @ObservedObject var store: TaskStore
    var openTasks: () -> Void
    var dragStarted: () -> Void
    var dragMoved: () -> Void
    var dragEnded: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    private var phase: TaskPhase {
        if store.attentionCount > 0 { return .waiting }
        if store.runningCount > 0 { return .running }
        if store.active.isEmpty && !store.finished.isEmpty { return .completed }
        return .idle
    }
    var body: some View {
        ZStack {
            Circle().fill(.black)
            Circle().stroke(phase.tint.opacity(0.20), lineWidth: 2.5).padding(5)
            if phase == .running {
                Circle().trim(from: 0.08, to: 0.76)
                    .stroke(phase.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).padding(5)
                    .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false), value: rotating)
                    .onAppear { rotating = true }
            } else {
                Circle().stroke(phase.tint, lineWidth: 2.5).padding(5)
                if phase == .waiting { Circle().fill(phase.tint).frame(width: 5, height: 5) }
            }
            WindowDragHandle(started: dragStarted, moved: dragMoved, ended: dragEnded, showsGrip: false)
        }
        .overlay(Circle().stroke(store.dockingHint ? Palette.accent : .clear, lineWidth: 1))
        .help(store.dockingHint ? "松手收进状态栏" : "\(store.runningCount) 个运行中 · \(store.attentionCount) 个待处理\n悬停查看，拖动移动")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex Top 圆环，\(store.runningCount) 个任务运行中，\(store.attentionCount) 个待处理")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openTasks() }
        .environment(\.colorScheme, .dark)
    }
}
