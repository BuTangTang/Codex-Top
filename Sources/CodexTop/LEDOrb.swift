import AppKit
import CodexTopCore
import QuartzCore
import SwiftUI

/// D-89 LED 点阵悬浮球：数字和暗灯用几块形状层画，绕圈的 5 颗蓝灯交给 Core Animation，任务刷新只改内容不逐帧计算。
struct LEDOrb: NSViewRepresentable {
    var groups: [LEDOrbLayout.Group]
    var ring: LEDOrbView.RingMode
    var dark: Bool
    var hovered: Bool
    /// 可见且没有开减少动态效果时才绕圈。
    var animating: Bool

    func makeNSView(context: Context) -> LEDOrbView { LEDOrbView() }

    func updateNSView(_ view: LEDOrbView, context: Context) {
        view.update(groups: groups, ring: ring, dark: dark, hovered: hovered, animating: animating)
    }

    static func dismantleNSView(_ view: LEDOrbView, coordinator: ()) { view.stopComet() }
}

final class LEDOrbView: NSView {
    enum RingMode: Equatable { case idle, running, done }
    static let step: CFTimeInterval = 0.05
    static let animationKey = "codexTop.ledRing"
    /// 5 颗：最前面全亮，后面 4 颗依次变暗。
    static let tail: [Float] = [1, 0.7, 0.45, 0.25, 0.12]
    private static let epoch = CACurrentMediaTime()
    /// 换组的过渡时长，和窗口变宽的弹簧（约 0.28 秒）同步。
    static let transition: CFTimeInterval = 0.3

    private var toneLayers: [LEDOrbLayout.Tone: CAShapeLayer] = [:]
    private let faint = CAShapeLayer(), dividers = CAShapeLayer(), doneRing = CAShapeLayer()
    private(set) var comet: [CALayer] = []
    private var groups: [LEDOrbLayout.Group] = []
    private var mode: RingMode = .idle
    private var dark = true
    private var animating = false
    /// 上一帧每组（按颜色区分）最左一颗灯的位置，用来算换组时的滑动距离。
    private var groupX: [LEDOrbLayout.Tone: CGFloat] = [:]
    private var dividerCount = 0
    /// 1 倍屏上 3 像素的灯做圆角会变成“+”字形，所以只在 2 倍屏上给一点圆角。
    private var corner: CGFloat { (window?.backingScaleFactor ?? 2) >= 2 ? 0.75 : 0 }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 45, height: LEDOrbLayout.height))
        wantsLayer = true
        for tone in [LEDOrbLayout.Tone.running, .idle, .waiting, .failed, .done] { toneLayers[tone] = CAShapeLayer() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(groups: [LEDOrbLayout.Group], ring: RingMode, dark: Bool, hovered: Bool, animating: Bool) {
        let rebuild = groups != self.groups || ring != mode || dark != self.dark
        // 从一个数变成两个、三个（或反过来）时做过渡；第一次出现、看不见或减少动态效果时直接换。
        let transition = groups != self.groups && !self.groups.isEmpty && animating && window != nil
        self.groups = groups; mode = ring; self.dark = dark; self.animating = animating
        withoutActions {
            layer?.backgroundColor = Self.color(dark ? (hovered ? 0x14171C : 0x0B0D10) : (hovered ? 0xEAECEF : 0xF3F4F6)).cgColor
        }
        if rebuild { redraw(transition: transition) }
        updateComet()
    }

    override func layout() {
        super.layout()
        redraw(transition: false)
        updateComet()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// 在内置屏（2 倍）和外接屏（1 倍）之间拖动时，形状层按新屏幕的像素密度重新栅格化。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidHide() { super.viewDidHide(); stopComet() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateComet() }

    private func redraw(transition: Bool) {
        guard let host = layer else { return }
        let layout = LEDOrbLayout.layout(groups)
        let faintColor = (dark ? NSColor.white : NSColor.black)
        var newX: [LEDOrbLayout.Tone: CGFloat] = [:], newRight: [LEDOrbLayout.Tone: CGFloat] = [:]
        for dot in layout.dots {
            newX[dot.tone] = min(newX[dot.tone] ?? .infinity, dot.rect.minX)
            newRight[dot.tone] = max(newRight[dot.tone] ?? 0, dot.rect.maxX)
        }
        withoutActions {
            for child in [faint, dividers, doneRing] + Array(toneLayers.values) where child.superlayer !== host { host.addSublayer(child) }
            for child in [faint, dividers, doneRing] + Array(toneLayers.values) { child.frame = bounds }
            for (tone, shape) in toneLayers {
                let oldPath = shape.path
                shape.path = path(layout.dots.filter { $0.lit && $0.tone == tone }.map(\.rect))
                shape.fillColor = color(for: tone).cgColor
                guard transition else { continue }
                switch (groupX[tone], newX[tone]) {
                case let (old?, new?) where old != new:
                    // 已有的一组从旧位置滑到新位置。
                    let slide = CABasicAnimation(keyPath: "transform.translation.x")
                    slide.fromValue = old - new; slide.toValue = 0
                    slide.duration = Self.transition; slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    shape.add(slide, forKey: "codexTop.ledSlide")
                case let (nil, new?):
                    // 新出现的一组像点阵屏开机一样从左往右逐列亮起。
                    reveal(shape, from: new - 1, width: (newRight[tone] ?? new) - new + 2)
                case (_?, nil):
                    // 消失的一组淡出。
                    fadeOut(path: oldPath, color: color(for: tone), in: host)
                default: break
                }
            }
            if transition && layout.dividers.count > dividerCount {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.2
                fade.beginTime = CACurrentMediaTime() + 0.1; fade.fillMode = .backwards
                dividers.add(fade, forKey: "codexTop.ledDividers")
            }
            groupX = newX.mapValues { $0 }; dividerCount = layout.dividers.count
            var unlit = layout.dots.filter { !$0.lit }.map(\.rect)
            if mode != .done { unlit += layout.ring }
            faint.path = path(unlit)
            faint.fillColor = faintColor.withAlphaComponent(0.07).cgColor
            dividers.path = { let path = CGMutablePath(); layout.dividers.forEach { path.addRect($0) }; return path }()
            dividers.fillColor = faintColor.withAlphaComponent(0.12).cgColor
            doneRing.path = mode == .done ? path(layout.ring) : nil
            doneRing.fillColor = color(for: .done).withAlphaComponent(0.45).cgColor
            applyContentsScale()
        }
    }

    private func updateComet() {
        let ring = mode == .running ? LEDOrbLayout.layout(groups).ring : []
        withoutActions {
            if comet.count != ring.count {
                comet.forEach { $0.removeFromSuperlayer() }
                comet = ring.map { _ in CALayer() }
            }
            guard let host = layer else { return }
            let blue = Self.color(dark ? 0x4E9BFF : 0x1F7AE0).cgColor
            for (index, dot) in comet.enumerated() {
                if dot.superlayer !== host { host.addSublayer(dot) }
                dot.frame = ring[index]
                dot.cornerRadius = corner
                dot.backgroundColor = blue
            }
            applyContentsScale()
        }
        guard !comet.isEmpty, animating, window != nil, !isHiddenOrHasHiddenAncestor else {
            stopComet()
            // 不能动时（减少动态效果、隐藏）停在一处：从左上角起的 5 颗，头在前、尾巴在后。
            withoutActions {
                for (index, dot) in comet.enumerated() { dot.opacity = index < Self.tail.count ? Self.tail[Self.tail.count - 1 - index] : 0 }
            }
            return
        }
        let count = Double(comet.count)
        for (index, dot) in comet.enumerated() where dot.animation(forKey: Self.animationKey) == nil {
            dot.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = Self.tail.map { NSNumber(value: $0) } + [0, 0]
            animation.keyTimes = (0...Self.tail.count).map { NSNumber(value: Double($0) / count) } + [1]
            animation.duration = count * Self.step
            animation.repeatCount = .infinity
            // 第 n 颗比第 0 颗晚 n 步亮，灯圈是顺时针排的，所以亮点顺时针跑；共享起点，刷新不打乱相位。
            animation.beginTime = dot.convertTime(Self.epoch, from: nil) + Double(index) * Self.step
            animation.fillMode = .backwards
            dot.add(animation, forKey: Self.animationKey)
        }
    }

    func stopComet() {
        for dot in comet where dot.animation(forKey: Self.animationKey) != nil { dot.removeAnimation(forKey: Self.animationKey) }
    }

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for child in [faint, dividers, doneRing] + Array(toneLayers.values) + comet { child.contentsScale = scale }
    }

    private func color(for tone: LEDOrbLayout.Tone) -> NSColor {
        switch tone {
        case .running: return Self.color(dark ? 0xFFFFFF : 0x1B1E24)
        case .idle: return Self.color(dark ? 0x7E858F : 0xA0A6AE)
        case .waiting: return Self.color(dark ? 0xF5AE3D : 0xE09A22)
        case .failed: return Self.color(dark ? 0xF2675F : 0xE0554D)
        case .done: return Self.color(dark ? 0x3FCB86 : 0x1FA866)
        }
    }

    private func path(_ rects: [CGRect]) -> CGPath {
        let path = CGMutablePath(), radius = corner
        for rect in rects {
            if radius > 0 { path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius) } else { path.addRect(rect) }
        }
        return path
    }

    /// 用一块从左往右变宽的遮罩把新的一组逐列露出来，结束后拿掉遮罩。
    private func reveal(_ shape: CAShapeLayer, from x: CGFloat, width: CGFloat) {
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mask.frame = CGRect(x: x, y: 0, width: width, height: LEDOrbLayout.height)
        shape.mask = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak shape] in if shape?.mask === mask { shape?.mask = nil } }
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0; grow.toValue = width
        grow.duration = Self.transition; grow.beginTime = CACurrentMediaTime() + 0.08; grow.fillMode = .backwards
        grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mask.add(grow, forKey: "codexTop.ledReveal")
        CATransaction.commit()
    }

    /// 消失的一组留一层旧图形淡出后移除。
    private func fadeOut(path: CGPath?, color: NSColor, in host: CALayer) {
        guard let path else { return }
        let ghost = CAShapeLayer()
        ghost.frame = bounds; ghost.path = path; ghost.fillColor = color.cgColor
        ghost.contentsScale = window?.backingScaleFactor ?? 2
        ghost.opacity = 0
        host.addSublayer(ghost)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.18
        ghost.add(fade, forKey: "codexTop.ledFade")
        CATransaction.commit()
    }

    /// 面板底色（深色 #0B0D10、浅色 #F3F4F6），窗口收缩过渡时也用它铺满，避免露出别的底色。
    static func panelColor(dark: Bool) -> Color {
        dark ? Color(.sRGB, red: 0x0B / 255, green: 0x0D / 255, blue: 0x10 / 255)
             : Color(.sRGB, red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF6 / 255)
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
