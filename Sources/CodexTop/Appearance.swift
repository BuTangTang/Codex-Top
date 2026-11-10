import SwiftUI
import CodexTopCore

// Values are in logical points. Keep typography and window geometry in agreement.
enum PanelMetrics {
    static let expandedWidth: CGFloat = 410
    static let floatingWidth: CGFloat = 360
    static let expandedRow: CGFloat = 54
    static let finishedRow: CGFloat = 36
    /// D-91 “刚完成”一段的段头。
    static let freshHeader: CGFloat = 28
    static let expandedHeader: CGFloat = 48
    static let floatingHeader: CGFloat = 44
    static let footer: CGFloat = 42
    /// 分隔线占一个物理像素；窗口预留高度与 SwiftUI 绘制必须使用相同的屏幕、界面缩放。
    static func separatorHeight(displayScale: CGFloat, uiScale: CGFloat) -> CGFloat {
        1 / (displayScale * uiScale)
    }

    static func rowHeight(for phase: TaskPhase) -> CGFloat {
        phase.isFinished ? finishedRow : expandedRow
    }
}

enum PanelFonts {
    static let header = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let task = Font.system(size: 16, weight: .medium)
    static let detail = Font.system(size: 14)
    static let label = Font.system(size: 14, weight: .medium)

    // Monitor surfaces use the same tighter type on every display and scale. Adjust
    // both the base and its floor, otherwise the old minimum cancels the reduction.
    static func readable(_ size: CGFloat, minimum: CGFloat = 12, scale: CGFloat,
                         weight: Font.Weight = .regular, compact: Bool = false) -> Font {
        let base = compact ? size - 2 : size
        let floor = compact ? max(11, minimum - 2) : minimum
        return .system(size: max(base, floor / max(CGFloat(MonitorScale.renderingScale(for: MonitorScale.minimum)), scale)), weight: weight)
    }
}

enum Palette {
    static let accent = Color(red: 0.19, green: 0.52, blue: 1)
    static let lightSurfaceWhite: CGFloat = 0.98
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
            .fontWeight(phase == .waiting ? .semibold : nil)
            .padding(.horizontal, phase == .waiting ? 6 : 0)
            .padding(.vertical, phase == .waiting ? 2 : 0)
            .background {
                if phase == .waiting {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(phase.tint(scheme).opacity(0.16))
                }
            }
    }
}

struct GlassFill: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if colorScheme == .light {
                Color(white: Palette.lightSurfaceWhite)
            } else {
                // D-90：深色底和 LED 悬浮球同一种近黑（#0B0D10），展开收起是一块。
                LEDOrbView.panelColor(dark: true)
            }
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
            .overlay(outline.stroke(.black.opacity(colorScheme == .dark ? 0 : 0.10), lineWidth: 0.6).padding(0.5))
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
    /// 监控面板的任务行用圆角悬停底；其他列表保持直角。
    var cornerRadius: CGFloat = 0
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.primary(colorScheme).opacity(configuration.isPressed ? 0.12 : hovered ? 0.055 : 0),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

@MainActor final class PanelPresentation: ObservableObject {
    @Published var placement: PanelPlacement?
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

