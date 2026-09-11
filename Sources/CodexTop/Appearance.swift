import SwiftUI
import CodexTopCore

// Values are in logical points. Keep typography and window geometry in agreement.
enum PanelMetrics {
    static let expandedWidth: CGFloat = 410
    static let floatingWidth: CGFloat = 360
    static let expandedRow: CGFloat = 54
    static let floatingRow: CGFloat = 42
    static let expandedHeader: CGFloat = 48
    static let floatingHeader: CGFloat = 44
    static let disclosure: CGFloat = 36
    static let footer: CGFloat = 42
}

enum PanelFonts {
    static let header = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let task = Font.system(size: 16, weight: .medium)
    static let detail = Font.system(size: 14)
    static let label = Font.system(size: 14, weight: .medium)

    // Desktop monitors and pinned lists use tighter type at every scale. Adjust
    // both the base and its floor, otherwise the old minimum cancels the reduction.
    static func readable(_ size: CGFloat, minimum: CGFloat = 12, scale: CGFloat,
                         weight: Font.Weight = .regular, compact: Bool = false) -> Font {
        let base = compact ? size - 2 : size
        let floor = compact ? max(11, minimum - 2) : minimum
        return .system(size: max(base, floor / max(CGFloat(MonitorScale.minimum), scale)), weight: weight)
    }
}

enum Palette {
    static let accent = Color(red: 0.19, green: 0.52, blue: 1)
    // Explicit endpoints can interpolate. Dynamic NSColor providers jump when AppKit changes appearance.
    static func primary(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white : Color(white: 0.12) }
    static func secondary(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.76 : 0.34) }
    static func hairline(_ scheme: ColorScheme) -> Color { (scheme == .dark ? Color.white : .black).opacity(0.10) }
}

extension PanelTheme {
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

enum ThemeMotion {
    static func transition(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.10 : 0.26)
    }
}

extension TaskPhase {
    func tint(_ scheme: ColorScheme) -> Color {
        switch self {
        case .running: scheme == .dark ? Palette.accent : Color(red: 0.12, green: 0.40, blue: 0.86)
        case .waiting: scheme == .dark ? Color(red: 1, green: 0.75, blue: 0.29) : Color(red: 0.91, green: 0.43, blue: 0.06)
        case .completed: scheme == .dark ? Color(red: 0.33, green: 0.76, blue: 0.56) : Color(red: 0.10, green: 0.53, blue: 0.30)
        case .failed: scheme == .dark ? Color(red: 1, green: 0.43, blue: 0.43) : Color(red: 0.78, green: 0.18, blue: 0.20)
        default: Palette.secondary(scheme)
        }
    }
    var symbol: String {
        switch self {
        case .running: "circle.dashed"
        case .waiting: "circle.fill"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .stopped: "stop.circle"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Keep small state labels readable without changing their status indicators.
struct TaskPhaseLabel: View {
    let phase: TaskPhase
    @Environment(\.colorScheme) private var scheme
    private var textColor: Color {
        if phase == .running { return Palette.primary(scheme) }
        if phase == .waiting && scheme == .light { return Color.black.opacity(0.82) }
        return phase.tint(scheme)
    }
    var body: some View {
        Text(phase.label)
            .foregroundStyle(textColor)
            .fontWeight(phase == .waiting ? .medium : nil)
            .padding(.horizontal, phase == .waiting ? 5 : 0)
            .padding(.vertical, phase == .waiting ? 2 : 0)
            .background {
                if phase == .waiting {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(phase.tint(scheme).opacity(0.12))
                }
            }
    }
}

@MainActor enum GlassMaterial {
    static func makeBackdrop(frame: CGRect = .zero) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: frame)
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        // Fade the tint, never the effect view: a translucent effect layer blends
        // the sharp window underneath back into the already blurred backdrop.
        view.alphaValue = 1
        return view
    }
}

struct FrostedBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        GlassMaterial.makeBackdrop()
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct GlassFill: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            FrostedBackdrop()
                .overlay(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(colorScheme == .light ? 1 : 0)
            Color.black.opacity(colorScheme == .dark ? 1 : 0)
        }
        .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: colorScheme)
        .allowsHitTesting(false)
    }
}

struct PanelSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content
    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content
            .background { GlassFill() }
            .clipShape(outline)
            .overlay(outline.stroke(.white.opacity(colorScheme == .dark ? 0 : 0.65), lineWidth: 0.6).padding(0.5))
            .foregroundStyle(Palette.primary(colorScheme))
            .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: colorScheme)
    }
}

struct ThemeToggleIcon: View {
    let theme: PanelTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Image(systemName: "sun.max")
                .opacity(theme == .dark ? 1 : 0)
                .rotationEffect(.degrees(reduceMotion || theme == .dark ? 0 : -35))
                .scaleEffect(reduceMotion || theme == .dark ? 1 : 0.8)
            Image(systemName: "moon")
                .opacity(theme == .light ? 1 : 0)
                .rotationEffect(.degrees(reduceMotion || theme == .light ? 0 : 35))
                .scaleEffect(reduceMotion || theme == .light ? 1 : 0.8)
        }
        .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: theme)
        .accessibilityHidden(true)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.primary(colorScheme).opacity(configuration.isPressed ? 0.14 : hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct QuietRowStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.primary(colorScheme).opacity(configuration.isPressed ? 0.12 : hovered ? 0.055 : 0))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

@MainActor final class PanelPresentation: ObservableObject {
    @Published var visible = false
}

struct AnimatedPanel<Content: View>: View {
    @ObservedObject var presentation: PanelPresentation
    var anchor: UnitPoint = .top
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        content
            .scaleEffect(reduceMotion || presentation.visible ? 1 : anchor == .top ? 0.72 : 0.86, anchor: anchor)
            .offset(y: reduceMotion || presentation.visible ? 0 : anchor == .top ? -14 : 0)
            .opacity(presentation.visible ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.10) : presentation.visible ? .smooth(duration: 0.24) : .easeInOut(duration: 0.18), value: presentation.visible)
    }
}

/// Scale the contents as well as their AppKit window, keeping hit targets and layout aligned.
struct ScaledPanel<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
        }
    }
}

/// The overlay catches header drags, while holes let buttons receive their own mouse events.
struct WindowDragHandle: View {
    var started: (CGSize) -> Void
    var moved: () -> Void
    var ended: () -> Void
    var excludedFrames: [CGRect] = []
    @State private var active = false
    var body: some View {
        Color.clear
            .contentShape(HeaderDragArea(excludedFrames: excludedFrames), eoFill: true)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !active { active = true; started(value.translation) }
                    moved()
                }
                .onEnded { _ in active = false; ended() })
    }
}

private struct HeaderDragArea: Shape {
    var excludedFrames: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for excluded in excludedFrames {
            let clipped = excluded.intersection(rect)
            if !clipped.isNull { path.addRect(clipped) }
        }
        return path
    }
}

struct ActivityIndicator: View {
    let phase: TaskPhase
    var small = false
    var animationsActive = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        let tint = phase.tint(colorScheme)
        ZStack {
            if phase == .running {
                Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                NativeRunningArc(tint: tint, rotating: animationsActive && visible && !reduceMotion, lineWidth: 3, inset: 1.5,
                                 trimStart: 0.12, trimEnd: 0.83, startDegrees: -70)
                    // Keep the original circle radius while containing its 3pt stroke.
                    .padding(-1.5)
                    .allowsHitTesting(false)
            } else if phase == .waiting {
                Circle().fill(tint.opacity(0.12))
                Circle().fill(tint).padding(6)
            } else {
                Image(systemName: phase.symbol).font(.system(size: small ? 17 : 18, weight: .medium)).foregroundStyle(tint)
            }
        }.frame(width: small ? 22 : 24, height: small ? 22 : 24)
            .animation(ThemeMotion.transition(reduceMotion: reduceMotion), value: colorScheme)
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .accessibilityHidden(true)
    }
}
