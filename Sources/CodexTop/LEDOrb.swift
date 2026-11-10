import AppKit
import CodexTopCore
import QuartzCore
import SwiftUI

/// D-89 LED 点阵悬浮球：数字和暗灯用几块形状层画，绕圈的 5 颗蓝灯交给 Core Animation，任务刷新只改内容不逐帧计算。
struct LEDOrb: NSViewRepresentable {
    var groups: [LEDOrbLayout.Group]
    var ring: LEDOrbView.RingMode
    /// 完成次数（TaskStore.completionSequence），变大说明刚有任务做完。
    var completions: Int
    var dark: Bool
    var hovered: Bool
    /// 可见且没有开减少动态效果时才绕圈。
    var animating: Bool

    func makeNSView(context: Context) -> LEDOrbView { LEDOrbView() }

    func updateNSView(_ view: LEDOrbView, context: Context) {
        view.update(groups: groups, ring: ring, completions: completions, dark: dark, hovered: hovered, animating: animating)
    }

    static func dismantleNSView(_ view: LEDOrbView, coordinator: ()) { view.stopComet() }
}

final class LEDOrbView: NSView {
    /// done：全部完成（进入时放一遍充电式庆祝）。
    enum RingMode: Equatable { case idle, running, done }
    static let step: CFTimeInterval = 0.05
    static let animationKey = "codexTop.ledRing"
    /// 5 颗：最前面全亮，后面 4 颗依次变暗。
    static let tail: [Float] = [1, 0.7, 0.45, 0.25, 0.12]
    /// 事件那 2 圈拉长到 12 颗。
    static let longTail: [Float] = (0..<12).map { Float(pow(1 - Double($0) / 12, 1.6)) }
    /// D-92：做完一个（绿）、等你（琥珀）、失败（红）时，蓝灯原地变色跑 2 圈。
    static let eventLaps: Double = 2
    /// 换组的过渡时长，和窗口变宽的弹簧（约 0.28 秒）同步。
    static let transition: CFTimeInterval = 0.3

    private var toneLayers: [LEDOrbLayout.Tone: CAShapeLayer] = [:]
    private let faint = CAShapeLayer(), dividers = CAShapeLayer()
    private(set) var comet: [CALayer] = []
    /// 绕圈的灯都放在 cometHost 里：调它的速度就能减速停下、再起步，位置不跳。
    /// 淡入淡出放在外面一层 cometFader 上，不受减速影响。
    private let cometFader = CALayer(), cometHost = CALayer()
    /// 第 0 颗灯最亮的时刻（cometHost 自己的时间）；宽度变了按“跑到一圈的几分之几”重新算，不跳位置。
    private var cometOrigin: CFTimeInterval = 0
    private enum CometState { case hidden, moving, stopping }
    private var cometState = CometState.hidden
    /// 速度渐变、事件结束的延时任务，状态一变就作废旧的。
    private var cometGeneration = 0
    /// 外圈灯现在的颜色（nil 为蓝）；lapRunning 表示事件那 2 圈还没跑完。
    private var lapColor: NSColor?
    private var lapRunning = false
    private var lapGeneration = 0
    private var completions: Int?
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

    func update(groups: [LEDOrbLayout.Group], ring: RingMode, completions: Int, dark: Bool, hovered: Bool, animating: Bool) {
        let rebuild = groups != self.groups || ring != mode || dark != self.dark
        // 从一个数变成两个、三个（或反过来）时做过渡；第一次出现、看不见或减少动态效果时直接换。
        let transition = groups != self.groups && !self.groups.isEmpty && animating && window != nil
        // D-91：刚变成全部完成时放一遍充电式庆祝。
        let celebrate = transition && ring == .done && mode != .done
        // D-92：失败、等你的个数变多或刚做完一个（没到全部完成），蓝灯原地变色跑 2 圈。
        var event: NSColor?
        if transition, ring != .done {
            if Self.count(.failed, in: groups) > Self.count(.failed, in: self.groups) { event = Self.toneColor(.failed, dark: dark) }
            else if Self.count(.waiting, in: groups) > Self.count(.waiting, in: self.groups) { event = Self.toneColor(.waiting, dark: dark) }
            else if let old = self.completions, completions > old { event = Self.toneColor(.done, dark: dark) }
        }
        self.groups = groups; mode = ring; self.dark = dark; self.animating = animating; self.completions = completions
        withoutActions {
            layer?.backgroundColor = Self.color(dark ? (hovered ? 0x14171C : 0x0B0D10) : (hovered ? 0xEAECEF : 0xF3F4F6)).cgColor
        }
        if rebuild { redraw(transition: transition, revealDelay: celebrate ? 1.3 : nil) }
        if celebrate { sweep() }
        if let event { startLap(event) }
        updateComet()
    }

    private static func count(_ tone: LEDOrbLayout.Tone, in groups: [LEDOrbLayout.Group]) -> Int {
        groups.first { $0.tone == tone }.flatMap { Int($0.text.filter(\.isNumber)) } ?? 0
    }

    override func layout() {
        super.layout()
        redraw(transition: false, revealDelay: nil)
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

    override func viewDidHide() { super.viewDidHide(); stopComet(); updateComet() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateComet() }

    private func redraw(transition: Bool, revealDelay: CFTimeInterval?) {
        guard let host = layer else { return }
        let layout = LEDOrbLayout.layout(groups)
        let faintColor = (dark ? NSColor.white : NSColor.black)
        var newX: [LEDOrbLayout.Tone: CGFloat] = [:], newRight: [LEDOrbLayout.Tone: CGFloat] = [:]
        for dot in layout.dots {
            newX[dot.tone] = min(newX[dot.tone] ?? .infinity, dot.rect.minX)
            newRight[dot.tone] = max(newRight[dot.tone] ?? 0, dot.rect.maxX)
        }
        withoutActions {
            for child in [faint, dividers] + Array(toneLayers.values) where child.superlayer !== host { host.addSublayer(child) }
            for child in [faint, dividers] + Array(toneLayers.values) { child.frame = bounds }
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
                    reveal(shape, from: new - 1, width: (newRight[tone] ?? new) - new + 2, delay: revealDelay ?? 0.08,
                           duration: revealDelay == nil ? Self.transition : 0.5)
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
            // 外圈平时都是暗灯；全部完成的庆祝结束后也退回暗灯，只留中间的 OK。
            faint.path = path(layout.dots.filter { !$0.lit }.map(\.rect) + layout.ring)
            faint.fillColor = faintColor.withAlphaComponent(0.07).cgColor
            dividers.path = { let path = CGMutablePath(); layout.dividers.forEach { path.addRect($0) }; return path }()
            dividers.fillColor = faintColor.withAlphaComponent(0.12).cgColor
            applyContentsScale()
        }
        // 休眠 Zz 慢慢呼吸；其他时候不呼吸。
        let sleepKey = "codexTop.ledSleep"
        if groups.first?.text == "Zz", animating, let shape = toneLayers[.done] {
            if shape.animation(forKey: sleepKey) == nil {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.9; breathe.toValue = 0.3; breathe.duration = 1.6
                breathe.autoreverses = true; breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shape.add(breathe, forKey: sleepKey)
            }
        } else { toneLayers[.done]?.removeAnimation(forKey: sleepKey) }
    }

    /// 全部完成时外圈一次性的绿色动画：顺时针充满（最前面最亮）→ 整圈闪两下 → 从起点顺时针退回暗灯，约 3 秒。
    /// 用临时图层播放，播完移除。
    private func sweep() {
        let full = true
        guard let host = layer else { return }
        let ring = LEDOrbLayout.layout(groups).ring, count = Double(ring.count)
        let duration: Double = full ? 3 : 1.2
        let green = color(for: .done).cgColor, radius = corner, scale = window?.backingScaleFactor ?? 2
        var dots: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { dots.forEach { $0.removeFromSuperlayer() } }
        for (index, rect) in ring.enumerated() {
            let fill = (full ? 1.0 : 0.6) * Double(index) / count
            let unwind = full ? 1.45 + 1.55 * Double(index) / count : 0.7 + 0.45 * Double(index) / count
            var points: [(Double, Double)] = [(0, 0), (fill, 0), (fill + 0.02, 1), (fill + 0.12, 0.8)]
            if full {
                points += [(1.0, 0.8), (1.02, 1), (1.15, 1), (1.17, 0.3), (1.25, 0.3), (1.27, 1), (1.4, 1), (1.45, 0.8)]
            }
            points += [(unwind, 0.8), (unwind + 0.08, 0), (duration, 0)]
            // 关键时间必须严格递增；时间相撞的点（宽面板最后几颗）直接跳过。
            var times: [Double] = [], values: [Double] = []
            for (time, value) in points where times.last.map({ time > $0 }) ?? true && time <= duration {
                times.append(time); values.append(value)
            }
            let dot = CALayer()
            dot.frame = rect; dot.backgroundColor = green; dot.cornerRadius = radius; dot.contentsScale = scale; dot.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = values.map { NSNumber(value: $0) }
            animation.keyTimes = times.map { NSNumber(value: $0 / duration) }
            animation.duration = duration
            dot.add(animation, forKey: "codexTop.ledSweep")
            host.addSublayer(dot); dots.append(dot)
        }
        CATransaction.commit()
    }

    private var cometNow: CFTimeInterval { cometHost.convertTime(CACurrentMediaTime(), from: nil) }

    /// 灯圈的灯数、颜色、位置跟上当前排版；再按“该不该转”起步或停下。
    private func updateComet() {
        let ring = LEDOrbLayout.layout(groups).ring
        guard let host = layer else { return }
        withoutActions {
            if cometFader.superlayer !== host { host.addSublayer(cometFader); cometFader.addSublayer(cometHost) }
            cometFader.frame = bounds; cometHost.frame = bounds
            if comet.count != ring.count {
                let hadAnimations = comet.first?.animation(forKey: Self.animationKey) != nil
                // 宽度变了：按旧灯数算出现在跑到一圈的几分之几，换成新灯数后从同一处接着跑。
                if !comet.isEmpty {
                    let now = cometNow, old = Double(comet.count) * Self.step
                    let fraction = ((now - cometOrigin).truncatingRemainder(dividingBy: old) + old).truncatingRemainder(dividingBy: old) / old
                    cometOrigin = now - fraction * Double(ring.count) * Self.step
                }
                comet.forEach { $0.removeFromSuperlayer() }
                comet = ring.map { _ in CALayer() }
                comet.forEach { cometHost.addSublayer($0) }
                if hadAnimations { installCometAnimations() }
            }
            let color = (lapColor ?? Self.blue(dark: dark)).cgColor
            for (index, dot) in comet.enumerated() {
                dot.frame = ring[index]; dot.cornerRadius = corner; dot.backgroundColor = color
            }
            applyContentsScale()
        }
        guard animating, window != nil, !isHiddenOrHasHiddenAncestor else {
            // 不能动时（减少动态效果、隐藏）停在一处：在跑就从左上角起亮 5 颗，头在前、尾巴在后。
            cometGeneration += 1; lapGeneration += 1; cometState = .hidden; lapColor = nil; lapRunning = false
            withoutActions {
                comet.forEach { $0.removeAnimation(forKey: Self.animationKey); $0.backgroundColor = Self.blue(dark: dark).cgColor }
                cometHost.speed = 1; cometHost.timeOffset = 0; cometHost.beginTime = 0
                cometFader.removeAllAnimations()
                cometFader.opacity = mode == .running ? 1 : 0
                for (index, dot) in comet.enumerated() { dot.opacity = index < Self.tail.count ? Self.tail[Self.tail.count - 1 - index] : 0 }
            }
            return
        }
        let shouldMove = mode == .running || lapRunning
        if shouldMove, cometState != .moving { startComet() }
        if !shouldMove, cometState == .moving { stopMoving(quick: mode == .done) }
    }

    private func installCometAnimations() {
        let tail = lapRunning ? Self.longTail : Self.tail
        let count = Double(comet.count)
        guard count > Double(tail.count) else { return }
        for (index, dot) in comet.enumerated() {
            dot.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = tail.map { NSNumber(value: $0) } + [0, 0]
            animation.keyTimes = (0...tail.count).map { NSNumber(value: Double($0) / count) } + [1]
            animation.duration = count * Self.step
            animation.repeatCount = .infinity
            // 第 n 颗比第 0 颗晚 n 步亮，灯圈是顺时针排的，所以亮点顺时针跑。
            animation.beginTime = cometOrigin + Double(index) * Self.step
            animation.fillMode = .backwards
            dot.add(animation, forKey: Self.animationKey)
        }
    }

    /// 改 cometHost 的速度而不让位置跳：把“现在”记成新的起点。
    private func setCometSpeed(_ speed: Float) {
        let local = cometNow, parent = cometFader.convertTime(CACurrentMediaTime(), from: nil)
        cometHost.speed = speed; cometHost.beginTime = parent; cometHost.timeOffset = local
    }

    /// 一串速度，每 interval 秒换一个；状态变了就不再往下换。
    private func rampSpeed(_ speeds: [Float], interval: TimeInterval, then: (() -> Void)? = nil) {
        cometGeneration += 1
        let generation = cometGeneration
        for (index, speed) in speeds.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index)) { [weak self] in
                guard let self, self.cometGeneration == generation else { return }
                self.setCometSpeed(speed)
                if index == speeds.count - 1 { then?() }
            }
        }
    }

    /// 从停下的地方（第一次就从左上角）渐亮起步，约 0.5 秒加速到正常速度。
    private func startComet() {
        let fromHidden = cometState == .hidden
        cometState = .moving
        withoutActions {
            if comet.first?.animation(forKey: Self.animationKey) == nil {
                cometOrigin = cometNow
                installCometAnimations()
            }
        }
        guard fromHidden else { rampSpeed([1], interval: 0); return }
        withoutActions {
            if lapColor == nil { comet.forEach { $0.backgroundColor = Self.blue(dark: dark).cgColor } }
            setCometSpeed(0.3)
            cometFader.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.4
            cometFader.add(fade, forKey: "codexTop.ledCometFade")
        }
        rampSpeed([0.3, 0.55, 0.8, 1], interval: 0.15)
    }

    /// 没有在跑的了：0.8 秒内减速、淡掉，停在原处；全部完成时 0.3 秒淡掉，给庆祝让位。
    private func stopMoving(quick: Bool) {
        cometState = .stopping
        let duration = quick ? 0.3 : 0.8
        withoutActions {
            cometFader.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            cometFader.add(fade, forKey: "codexTop.ledCometFade")
        }
        rampSpeed(quick ? [0.5, 0] : [0.7, 0.45, 0.25, 0.1, 0], interval: quick ? 0.15 : 0.2) { [weak self] in
            guard let self, self.cometState == .stopping else { return }
            self.cometState = .hidden
            // 停稳后颜色和尾巴回到平时的样子，下次起步就是蓝色 5 颗。
            self.lapColor = nil; self.lapRunning = false
            self.withoutActions {
                self.installCometAnimations()
                self.comet.forEach { $0.backgroundColor = Self.blue(dark: self.dark).cgColor }
            }
        }
    }

    /// 原地变色、尾巴拉长跑 2 圈；还有在跑的就变回蓝色，没有就减速熄掉。
    private func startLap(_ color: NSColor) {
        let fromColor = lapColor ?? Self.blue(dark: dark)
        lapColor = color; lapRunning = true
        lapGeneration += 1
        let generation = lapGeneration
        withoutActions {
            if cometState != .hidden { installCometAnimations() }
            for dot in comet {
                dot.backgroundColor = color.cgColor
                let tint = CABasicAnimation(keyPath: "backgroundColor")
                tint.fromValue = fromColor.cgColor; tint.toValue = color.cgColor; tint.duration = 0.15
                dot.add(tint, forKey: "codexTop.ledCometTint")
            }
        }
        let laps = Self.eventLaps * Double(max(comet.count, LEDOrbLayout.layout(groups).ring.count)) * Self.step
        DispatchQueue.main.asyncAfter(deadline: .now() + laps) { [weak self] in
            guard let self, self.lapGeneration == generation, self.lapRunning else { return }
            self.lapRunning = false
            if self.mode == .running {
                self.lapColor = nil
                self.withoutActions {
                    self.installCometAnimations()
                    for dot in self.comet {
                        dot.backgroundColor = Self.blue(dark: self.dark).cgColor
                        let tint = CABasicAnimation(keyPath: "backgroundColor")
                        tint.fromValue = color.cgColor; tint.toValue = Self.blue(dark: self.dark).cgColor; tint.duration = 0.5
                        dot.add(tint, forKey: "codexTop.ledCometTint")
                    }
                }
            } else {
                // 颜色留着一起熄掉，停稳后再换回蓝色。
                self.stopMoving(quick: self.mode == .done)
            }
        }
    }

    func stopComet() {
        cometGeneration += 1; lapGeneration += 1
        for dot in comet where dot.animation(forKey: Self.animationKey) != nil { dot.removeAnimation(forKey: Self.animationKey) }
    }

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for child in [faint, dividers, cometFader, cometHost] + Array(toneLayers.values) + comet { child.contentsScale = scale }
    }

    private func color(for tone: LEDOrbLayout.Tone) -> NSColor { Self.toneColor(tone, dark: dark) }

    /// 悬浮球、面板标题栏点阵屏、行首小灯共用的颜色。
    static func toneColor(_ tone: LEDOrbLayout.Tone, dark: Bool) -> NSColor {
        switch tone {
        case .running: return color(dark ? 0xFFFFFF : 0x1B1E24)
        case .idle: return color(dark ? 0x7E858F : 0xA0A6AE)
        case .waiting: return color(dark ? 0xF5AE3D : 0xE09A22)
        case .failed: return color(dark ? 0xF2675F : 0xE0554D)
        case .done: return color(dark ? 0x3FCB86 : 0x1FA866)
        }
    }
    static func blue(dark: Bool) -> NSColor { color(dark ? 0x4E9BFF : 0x1F7AE0) }

    private func path(_ rects: [CGRect]) -> CGPath {
        let path = CGMutablePath(), radius = corner
        for rect in rects {
            if radius > 0 { path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius) } else { path.addRect(rect) }
        }
        return path
    }

    /// 用一块从左往右变宽的遮罩把新的一组逐列露出来，结束后拿掉遮罩。
    private func reveal(_ shape: CAShapeLayer, from x: CGFloat, width: CGFloat, delay: CFTimeInterval, duration: CFTimeInterval) {
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mask.frame = CGRect(x: x, y: 0, width: width, height: LEDOrbLayout.height)
        shape.mask = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak shape] in if shape?.mask === mask { shape?.mask = nil } }
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0; grow.toValue = width
        grow.duration = duration; grow.beginTime = CACurrentMediaTime() + delay; grow.fillMode = .backwards
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

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// D-90 面板标题栏右边的小点阵屏：和悬浮球同一套字形和颜色，点 2、间距 1，显示 在跑｜等你｜失败。
struct LEDMiniSummary: View {
    let groups: [LEDOrbLayout.Group]
    let dark: Bool
    private static let pitch: CGFloat = 3, dot: CGFloat = 2
    private var width: CGFloat {
        // 每组：字数×12 减去最后一格空隙；组间 7（左右各空 3、中间 1 点分隔线）。
        let digits = groups.reduce(0) { $0 + $1.text.count }
        return CGFloat(digits) * 4 * Self.pitch - Self.pitch * CGFloat(groups.count) + CGFloat(max(0, groups.count - 1)) * 7
    }
    var body: some View {
        Canvas { context, _ in
            let off = Color(dark ? .white : .black).opacity(0.08)
            var x: CGFloat = 0
            for (index, group) in groups.enumerated() {
                if index > 0 {
                    context.fill(Path(CGRect(x: x + 3, y: 1, width: 1, height: 12)), with: .color(Color(dark ? .white : .black).opacity(0.14)))
                    x += 7
                }
                let lit = Color(nsColor: LEDOrbView.toneColor(group.tone, dark: dark))
                for character in group.text {
                    for (cell, on) in LEDOrbLayout.glyph(character).enumerated() {
                        let rect = CGRect(x: x + CGFloat(cell % 3) * Self.pitch, y: CGFloat(cell / 3) * Self.pitch, width: Self.dot, height: Self.dot)
                        context.fill(Path(rect), with: .color(on ? lit : off))
                    }
                    x += 4 * Self.pitch
                }
                x -= Self.pitch
            }
        }
        .frame(width: max(1, width), height: 14)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(LEDOrbView.panelColor(dark: dark), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(dark ? .white : .black).opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// D-90 行首小灯：在跑是 8 颗点一圈、亮点顺时针转；等你是琥珀 3×3 点阵轻闪；失败是红色 3×3；其余按状态色静止。
struct LEDPip: NSViewRepresentable {
    var phase: TaskPhase
    var dark: Bool
    var animating: Bool
    func makeNSView(context: Context) -> LEDPipView { LEDPipView() }
    func updateNSView(_ view: LEDPipView, context: Context) { view.update(phase: phase, dark: dark, animating: animating) }
    static func dismantleNSView(_ view: LEDPipView, coordinator: ()) { view.stopAnimations() }
}

final class LEDPipView: NSView {
    static let size: CGFloat = 18
    /// 外圈 8 颗，从 12 点起顺时针；全部是整数点。
    static let ring: [CGPoint] = [CGPoint(x: 7, y: 1), CGPoint(x: 12, y: 3), CGPoint(x: 14, y: 7), CGPoint(x: 12, y: 12),
                                  CGPoint(x: 7, y: 14), CGPoint(x: 2, y: 12), CGPoint(x: 0, y: 7), CGPoint(x: 2, y: 3)]
    static let grid: [CGPoint] = (0..<9).map { CGPoint(x: 3 + CGFloat($0 % 3) * 4, y: 3 + CGFloat($0 / 3) * 4) }
    private static let epoch = CACurrentMediaTime()
    private static let spinKey = "codexTop.pipSpin", pulseKey = "codexTop.pipPulse"
    private var dots: [CALayer] = []
    private var phase: TaskPhase?
    private var dark = true
    private var animating = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(phase: TaskPhase, dark: Bool, animating: Bool) {
        let changed = phase != self.phase || dark != self.dark
        self.phase = phase; self.dark = dark; self.animating = animating
        if changed { rebuild() }
        updateAnimations()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuild(); updateAnimations() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); rebuild(); updateAnimations() }
    override func viewDidHide() { super.viewDidHide(); stopAnimations() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimations() }

    private func rebuild() {
        guard let host = layer, let phase else { return }
        stopAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dots.forEach { $0.removeFromSuperlayer() }
        let points = phase == .running ? Self.ring : Self.grid
        let color: NSColor
        switch phase {
        case .running: color = LEDOrbView.blue(dark: dark)
        case .waiting: color = LEDOrbView.toneColor(.waiting, dark: dark)
        case .failed: color = LEDOrbView.toneColor(.failed, dark: dark)
        case .completed: color = LEDOrbView.toneColor(.done, dark: dark)
        default: color = LEDOrbView.toneColor(.idle, dark: dark)
        }
        let scale = window?.backingScaleFactor ?? 2
        dots = points.map { point in
            let dot = CALayer()
            dot.frame = CGRect(origin: point, size: CGSize(width: 3, height: 3))
            dot.backgroundColor = color.cgColor
            dot.cornerRadius = scale >= 2 ? 0.6 : 0   // 1 倍屏 3 像素的点不做圆角
            dot.contentsScale = scale
            dot.opacity = phase == .unknown || phase == .stopped || phase == .idle ? 0.55 : 1
            host.addSublayer(dot)
            return dot
        }
        CATransaction.commit()
    }

    private func updateAnimations() {
        guard let phase, animating, window != nil, !isHiddenOrHasHiddenAncestor, phase == .running || phase == .waiting else {
            stopAnimations()
            if phase == .running {
                // 不能动时停在 12 点方向：头最亮，逆时针一侧依次变暗。
                CATransaction.begin(); CATransaction.setDisableActions(true)
                for (index, dot) in dots.enumerated() { dot.opacity = [1, 0.15, 0.15, 0.15, 0.15, 0.15, 0.3, 0.55][index % 8] }
                CATransaction.commit()
            }
            return
        }
        if phase == .running {
            for (index, dot) in dots.enumerated() where dot.animation(forKey: Self.spinKey) == nil {
                dot.opacity = 0.15
                let spin = CAKeyframeAnimation(keyPath: "opacity")
                spin.values = [1, 0.55, 0.3, 0.15, 0.15]
                spin.keyTimes = [0, 0.125, 0.25, 0.375, 1]
                spin.duration = 0.8
                spin.repeatCount = .infinity
                // 第 n 颗晚 n/8 圈亮，点是顺时针排的，所以亮点顺时针转。
                spin.beginTime = dot.convertTime(Self.epoch, from: nil) + Double(index) * 0.1
                spin.fillMode = .backwards
                dot.add(spin, forKey: Self.spinKey)
            }
        } else if let host = layer, host.animation(forKey: Self.pulseKey) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.45
            pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            host.add(pulse, forKey: Self.pulseKey)
        }
    }

    func stopAnimations() {
        layer?.removeAnimation(forKey: Self.pulseKey)
        for dot in dots { dot.removeAnimation(forKey: Self.spinKey) }
    }
}

