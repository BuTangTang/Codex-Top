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
    static let header = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let task = Font.system(size: 14, weight: .medium)
    static let detail = Font.system(size: 12)
    static let label = Font.system(size: 13, weight: .medium)
}

enum Palette {
    static let hairline = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.10) })
    static let accent = Color(red: 0.19, green: 0.52, blue: 1)
    static let primary = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : NSColor(calibratedWhite: 0.12, alpha: 1) })
    static let secondary = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.65, alpha: 1) : NSColor(calibratedWhite: 0.40, alpha: 1) })
}

extension TaskPhase {
    var tint: Color {
        switch self {
        case .running: Palette.accent
        case .waiting: Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 1, green: 0.75, blue: 0.29, alpha: 1) : NSColor(calibratedRed: 0.63, green: 0.36, blue: 0.025, alpha: 1) })
        case .completed: Color(red: 0.33, green: 0.76, blue: 0.56)
        case .failed: Color(red: 1, green: 0.43, blue: 0.43)
        default: Palette.secondary
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

struct FrostedBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = 0.72
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct GlassFill: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if colorScheme == .dark {
            Color.black
        } else {
            FrostedBackdrop().overlay(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

struct PanelSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content
    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content
            .background { GlassFill() }
            .clipShape(outline)
            .overlay(outline.stroke(.white.opacity(colorScheme == .dark ? 0 : 0.65), lineWidth: 0.6).padding(0.5))
            .foregroundStyle(Palette.primary)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct QuietRowStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.055 : 0))
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

struct WindowDragHandle: View {
    var started: () -> Void
    var moved: () -> Void
    var ended: () -> Void
    var showsGrip = true
    @State private var active = false
    var body: some View {
        Color.clear
            .overlay {
                if showsGrip { Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !active { active = true; started() }
                    moved()
                }
                .onEnded { _ in active = false; ended() })
        }
}

struct ActivityIndicator: View {
    let phase: TaskPhase
    var small = false
    var body: some View {
        ZStack {
            if phase == .running {
                Circle().stroke(phase.tint.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0.12, to: 0.83).stroke(phase.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-70))
            } else if phase == .waiting {
                Circle().fill(phase.tint.opacity(0.12))
                Circle().fill(phase.tint).padding(6)
            } else {
                Image(systemName: phase.symbol).font(.system(size: small ? 17 : 18, weight: .medium)).foregroundStyle(phase.tint)
            }
        }.frame(width: small ? 22 : 24, height: small ? 22 : 24)
            .accessibilityHidden(true)
    }
}
