import AppKit
import QuartzCore
import SwiftUI

/// D-88 圆球上的 12 根转圈刻度（2026-11-09 用户要和 D 方案一样密）：在跑时最亮的一根顺时针前进、后面拖着渐暗的尾巴，像系统的转圈指示。
/// Core Animation 负责动画，任务刷新只改颜色和开关，不重排、不逐帧计时。
struct TickSpinner: NSViewRepresentable {
    var color: Color
    /// 转圈动画。
    var spinning: Bool
    /// 不转时是否画成静止的明暗梯度（减少动态效果、或刚完成闪绿时用）；否则所有刻度同一透明度。
    var gradient: Bool
    var opacity: CGFloat

    func makeNSView(context: Context) -> TickSpinnerView { TickSpinnerView() }

    func updateNSView(_ view: TickSpinnerView, context: Context) {
        view.update(color: NSColor(color), spinning: spinning, gradient: gradient, opacity: opacity)
    }

    static func dismantleNSView(_ view: TickSpinnerView, coordinator: ()) { view.stop() }
}

final class TickSpinnerView: NSView {
    static let count = 12
    static let period: CFTimeInterval = 1.0
    static let animationKey = "codexTop.tickSpinner"
    static let dimmest: Float = 0.22
    private static let epoch = CACurrentMediaTime()
    private static let innerRadius: CGFloat = 13.4
    private static let outerRadius: CGFloat = 19.2
    private static let lineWidth: CGFloat = 3

    private(set) var ticks: [CAShapeLayer] = []
    private var spinning = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        wantsLayer = true
        for _ in 0..<Self.count {
            let tick = CAShapeLayer()
            tick.fillColor = nil
            tick.lineCap = .round
            tick.lineWidth = Self.lineWidth
            ticks.append(tick)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutActions {
            guard let layer else { return }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            for (index, tick) in ticks.enumerated() {
                if tick.superlayer !== layer { layer.addSublayer(tick) }
                tick.frame = bounds
                tick.contentsScale = scale
                // 视图坐标向下为正，编号越大角度越往顺时针方向；0 号在 12 点。
                let angle = (CGFloat(index) * 360 / CGFloat(Self.count) - 90) * .pi / 180
                let path = CGMutablePath()
                path.move(to: CGPoint(x: center.x + cos(angle) * Self.innerRadius, y: center.y + sin(angle) * Self.innerRadius))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * Self.outerRadius, y: center.y + sin(angle) * Self.outerRadius))
                tick.path = path
            }
        }
        updateAnimation()
    }

    func update(color: NSColor, spinning: Bool, gradient: Bool, opacity: CGFloat) {
        withoutActions {
            for (index, tick) in ticks.enumerated() {
                tick.strokeColor = color.cgColor
                tick.opacity = gradient ? Self.gradientOpacity(index) : Float(opacity)
            }
        }
        self.spinning = spinning
        updateAnimation()
    }

    /// 静止时 0 号最亮，往逆时针方向（编号从大到小）逐根变暗，看起来正要顺时针转。
    static func gradientOpacity(_ index: Int) -> Float {
        let behind = (count - index) % count
        return max(dimmest, 1 - Float(behind) * (1 - dimmest) / Float(count - 1))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        updateAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidHide() { super.viewDidHide(); stop() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }

    private func updateAnimation() {
        guard spinning, window != nil, !isHiddenOrHasHiddenAncestor else { stop(); return }
        for (index, tick) in ticks.enumerated() where tick.animation(forKey: Self.animationKey) == nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = Self.dimmest
            animation.duration = Self.period
            animation.repeatCount = .infinity
            // 第 n 根比 0 号晚 n/12 圈变亮，最亮处于是顺时针前进；共享起点，刷新不打乱相位。
            animation.beginTime = tick.convertTime(Self.epoch, from: nil) + Self.period * Double(index) / Double(Self.count)
            animation.fillMode = .backwards
            tick.add(animation, forKey: Self.animationKey)
        }
    }

    func stop() {
        for tick in ticks where tick.animation(forKey: Self.animationKey) != nil { tick.removeAnimation(forKey: Self.animationKey) }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
