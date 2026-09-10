import SwiftUI
import CodexTopCore

/// Window geometry and the visible surface share a single progress value.
/// Closed windows really occupy only the status strip, so an invisible panel cannot eat clicks.
@MainActor final class TopPanelState: ObservableObject {
    @Published var progress: CGFloat = 0
    @Published var compactSize = CGSize(width: 250, height: 34)
    @Published var expandedSize = CGSize(width: 410, height: 340)
    @Published var surfaceSize = CGSize(width: 250, height: 34)
    @Published var cameraWidth: CGFloat = 0
    @Published var cameraHeight: CGFloat = 0
}

private struct TopSurfaceOutline: Shape {
    var progress: CGFloat
    var attached: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let bottomRadius = 14 + 8 * progress
        return UnevenRoundedRectangle(
            topLeadingRadius: attached ? 0 : bottomRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: attached ? 0 : bottomRadius,
            style: .continuous
        ).path(in: rect)
    }
}

struct TopPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: TopPanelState
    var open: () -> Void
    var pickTasks: () -> Void
    var settings: () -> Void
    var finishedChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func fade(_ value: CGFloat) -> Double {
        let t = min(1, max(0, value))
        return Double(t * t * (3 - 2 * t))
    }

    var body: some View {
        GeometryReader { geometry in
            let outline = TopSurfaceOutline(progress: state.progress, attached: state.cameraHeight > 0)
            ZStack(alignment: .top) {
                GlassFill()
                // The hardware notch always blends into black. Light glass emerges below it.
                Color.black.opacity(1 - Double(state.progress))
                if state.cameraHeight > 0 {
                    Color.black.frame(height: state.cameraHeight)
                }
                MonitorView(store: store, compact: false, drawsSurface: false,
                            pickTasks: pickTasks, settings: settings, finishedChanged: finishedChanged)
                    .frame(width: state.expandedSize.width / store.uiScale, height: max(1, (state.expandedSize.height - state.cameraHeight) / store.uiScale))
                    .scaleEffect(store.uiScale, anchor: .top)
                    .frame(width: state.expandedSize.width, height: max(1, state.expandedSize.height - state.cameraHeight), alignment: .top)
                    .offset(y: state.cameraHeight - (reduceMotion ? 0 : 8 * (1 - state.progress)))
                    .opacity(fade((state.progress - 0.28) / 0.72))
                    .animation(reduceMotion ? nil : state.progress > 0 ? .easeOut(duration: 0.16).delay(0.04) : .easeOut(duration: 0.09), value: state.progress)
                    .allowsHitTesting(state.progress > 0.92)
                    .accessibilityHidden(state.progress < 0.99)
                if store.placement == .top || store.placement == .floating {
                    CompactView(store: store, notchWidth: state.cameraWidth, drawsSurface: false, open: open)
                    .frame(width: state.compactSize.width, height: state.compactSize.height)
                    .opacity(1 - fade(state.progress / 0.32))
                    .allowsHitTesting(state.progress < 0.1)
                    .accessibilityHidden(state.progress >= 0.1)
                }
            }
            .frame(width: state.surfaceSize.width, height: state.surfaceSize.height, alignment: .top)
            .clipShape(outline)
            .overlay {
                if store.theme == .light {
                    outline.stroke(.white.opacity(0.65 * Double(state.progress)), lineWidth: 0.6).padding(0.5)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .environment(\.colorScheme, store.theme == .light ? .light : .dark)
    }
}
