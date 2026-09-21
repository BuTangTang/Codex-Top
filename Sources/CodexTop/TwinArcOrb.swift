import AppKit
import CodexTopCore
import QuartzCore
import SwiftUI

/// The two arcs show activity, never completion percentage. Only their shared
/// container rotates; counts, alerts and the hit target stay in the same place.
struct TwinArcOrb: View {
    let phase: TaskPhase
    let runningCount: Int
    let visible: Bool
    var hovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NativeTwinArcOrb(phase: phase, runningCount: runningCount, visible: visible,
                         hovered: hovered, dark: colorScheme == .dark, reduceMotion: reduceMotion)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

private struct NativeTwinArcOrb: NSViewRepresentable {
    let phase: TaskPhase
    let runningCount: Int
    let visible: Bool
    let hovered: Bool
    let dark: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> TwinArcOrbView { TwinArcOrbView() }

    func updateNSView(_ view: TwinArcOrbView, context: Context) {
        view.update(phase: phase, runningCount: runningCount, visible: visible,
                    hovered: hovered, dark: dark, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: TwinArcOrbView, coordinator: ()) {
        view.detach()
    }
}

/// Kept separate from NativeRunningArc so the original ring retains its geometry
/// and timing. A native layer tree also avoids a SwiftUI timer or per-frame layout.
final class TwinArcOrbView: NSView {
    static let rotationDuration: CFTimeInterval = 3.2
    static let rotationKey = "codexTop.twinArcRotation"
    private static let rotationEpoch = CACurrentMediaTime()
    private static let lineWidth: CGFloat = 2.5
    private static let outerMargin: CGFloat = 2.2

    private let surface = CAShapeLayer()
    private let rotor = CALayer()
    private let arcs = [CAGradientLayer(), CAGradientLayer()]
    private let masks = [CAShapeLayer(), CAShapeLayer()]
    private let center = CATextLayer()
    private let alert = CATextLayer()
    private var shouldRotate = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        wantsLayer = true
        setAccessibilityElement(false)
        surface.name = "twinArc.surface"
        rotor.name = "twinArc.rotor"
        center.name = "twinArc.center"
        alert.name = "twinArc.alert"
        surface.lineWidth = 0.6
        for index in arcs.indices {
            let gradient = arcs[index], mask = masks[index]
            gradient.name = "twinArc.arc.\(index)"
            gradient.locations = [0, 0.45, 1]
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = Self.lineWidth
            mask.lineCap = .round
            gradient.mask = mask
            rotor.addSublayer(gradient)
        }
        for text in [center, alert] {
            text.alignmentMode = .center
            text.truncationMode = .none
            text.isWrapped = false
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        // Keep the descriptor's tabular-number feature; rebuilding from fontName
        // alone would discard it and subtly shift different running counts.
        center.font = font
        center.fontSize = 17
        let alertFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        alert.font = alertFont
        alert.fontSize = 9
        attachLayers()
        update(phase: .idle, runningCount: 0, visible: false, hovered: false, dark: true, reduceMotion: false)
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutActions {
            attachLayers()
            let rect = CGRect(origin: .zero, size: bounds.size)
            surface.frame = rect
            surface.path = CGPath(ellipseIn: rect.insetBy(dx: 0.3, dy: 0.3), transform: nil)
            // Do not assign a transformed layer's frame: its value is undefined
            // after stopping rotation at an arbitrary angle.
            rotor.bounds = rect
            rotor.position = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - Self.outerMargin - Self.lineWidth / 2
            for index in arcs.indices {
                let start = -CGFloat.pi * 13 / 18 + CGFloat(index) * .pi
                let end = start + .pi * 4 / 9
                let path = CGMutablePath()
                path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(0, radius),
                            startAngle: start, endAngle: end, clockwise: false)
                arcs[index].frame = rect
                masks[index].frame = rect
                masks[index].path = path
                // Over an 80-degree arc, distance along this chord is monotonic.
                // An axial gradient gives a smooth tail without a conic seam.
                arcs[index].startPoint = CGPoint(x: (rect.midX + cos(start) * radius) / max(1, rect.width),
                                                y: (rect.midY + sin(start) * radius) / max(1, rect.height))
                arcs[index].endPoint = CGPoint(x: (rect.midX + cos(end) * radius) / max(1, rect.width),
                                              y: (rect.midY + sin(end) * radius) / max(1, rect.height))
            }
            center.frame = CGRect(x: rect.midX - 19, y: rect.midY - 11, width: 38, height: 22)
            alert.frame = CGRect(x: rect.midX - 6, y: rect.midY + 6, width: 12, height: 11)
            updateContentsScale()
        }
        updateRotation()
    }

    func update(phase: TaskPhase, runningCount: Int, visible: Bool,
                hovered: Bool = false, dark: Bool, reduceMotion: Bool) {
        let count = max(0, runningCount)
        let number = count > 99 ? "99+" : String(count)
        let foreground = Self.color(dark ? 0xF5F6F8 : 0x171B21)
        let muted = Self.color(dark ? 0x8B939E : 0x6B7480)
        let tint: NSColor
        let glyph: String
        var notice: String?
        switch phase {
        case .running:
            tint = Self.color(dark ? 0x479BFF : 0x0876E5); glyph = number
        case .waiting:
            tint = Self.color(dark ? 0xEAAA38 : 0xB66B00)
            glyph = count > 0 ? number : "!"
            if count > 0 { notice = "!" }
        case .failed:
            tint = Self.color(dark ? 0xF06C6C : 0xD53B3B)
            glyph = count > 0 ? number : "×"
            if count > 0 { notice = "×" }
        case .completed:
            tint = Self.color(dark ? 0x47CA8A : 0x16864A); glyph = "✓"
        case .stopped:
            tint = muted; glyph = "■"
        case .unknown:
            tint = muted; glyph = "?"
        case .idle:
            tint = muted; glyph = "0"
        }
        let activeArcs = phase == .running || phase == .waiting || phase == .failed
        withoutActions {
            surface.fillColor = Self.color(dark ? 0x171B21 : 0xFCFCFD).cgColor
            surface.strokeColor = foreground.withAlphaComponent(hovered ? 0.22 : 0.04).cgColor
            for arc in arcs {
                arc.colors = [0.25, 0.70, 1.0].map { tint.withAlphaComponent($0).cgColor }
                arc.opacity = activeArcs ? 1 : 0.45
            }
            center.string = glyph
            center.foregroundColor = (phase == .running || count > 0 && (phase == .waiting || phase == .failed)
                                      ? foreground : tint).cgColor
            alert.string = notice ?? ""
            alert.foregroundColor = tint.cgColor
            alert.isHidden = notice == nil
        }
        shouldRotate = phase == .running && visible && !reduceMotion
        updateRotation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                                                       name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
        needsLayout = true
        updateRotation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        withoutActions { updateContentsScale() }
    }

    override func viewDidHide() { super.viewDidHide(); stopRotation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateRotation() }

    func detach() {
        shouldRotate = false
        stopRotation()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowVisibilityChanged() { updateRotation() }
    @objc private func windowWillClose() { stopRotation() }

    private func attachLayers() {
        guard let layer else { return }
        for child in [surface, rotor, center, alert] where child.superlayer !== layer {
            layer.addSublayer(child)
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for child in [surface, rotor, center, alert] + arcs + masks { child.contentsScale = scale }
    }

    private func updateRotation() {
        guard shouldRotate, let window, window.isVisible, !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor else { stopRotation(); return }
        guard rotor.animation(forKey: Self.rotationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = Self.rotationDuration
        animation.beginTime = rotor.convertTime(Self.rotationEpoch, from: nil)
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotor.add(animation, forKey: Self.rotationKey)
    }

    private func stopRotation() {
        guard rotor.animation(forKey: Self.rotationKey) != nil else { return }
        let transform = rotor.presentation()?.transform ?? rotor.transform
        withoutActions {
            rotor.transform = transform
            rotor.removeAnimation(forKey: Self.rotationKey)
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
