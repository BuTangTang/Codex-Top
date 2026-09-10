import AppKit
import QuartzCore
import SwiftUI

/// Core Animation owns continuous rotation; task refreshes only update its inputs.
struct NativeRunningArc: NSViewRepresentable {
    var tint: Color
    var rotating: Bool
    var lineWidth: CGFloat = 1.8
    var inset: CGFloat = 7
    var trimStart: CGFloat = 0.08
    var trimEnd: CGFloat = 0.78
    var startDegrees: CGFloat = -90

    func makeNSView(context: Context) -> RunningArcView { RunningArcView() }

    func updateNSView(_ view: RunningArcView, context: Context) {
        view.update(tint: NSColor(tint), rotating: rotating, lineWidth: lineWidth, inset: inset,
                    trimStart: trimStart, trimEnd: trimEnd, startDegrees: startDegrees)
    }

    static func dismantleNSView(_ view: RunningArcView, coordinator: ()) {
        view.stopRotation()
    }
}

final class RunningArcView: NSView {
    private let arc = CAShapeLayer()
    private var rotating = false
    private var inset: CGFloat = 7
    private var startRadians: CGFloat = -.pi / 2
    private let rotationKey = "codexTop.runningRotation"
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 1.8
        arc.lineCap = .round
        arc.strokeStart = 0.08
        arc.strokeEnd = 0.78
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // AppKit can create or replace the backing layer after initialization.
        if let backingLayer = layer, arc.superlayer !== backingLayer { backingLayer.addSublayer(arc) }
        arc.bounds = CGRect(origin: .zero, size: bounds.size)
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.width / 2, y: bounds.height / 2),
                    radius: max(0, min(bounds.width, bounds.height) / 2 - inset),
                    startAngle: startRadians, endAngle: startRadians + .pi * 2, clockwise: false)
        arc.path = path
        arc.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateRotation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        updateRotation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidHide() { super.viewDidHide(); stopRotation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateRotation() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(tint: NSColor, rotating: Bool, lineWidth: CGFloat, inset: CGFloat,
                trimStart: CGFloat, trimEnd: CGFloat, startDegrees: CGFloat) {
        let radians = startDegrees * .pi / 180
        if self.inset != inset || startRadians != radians {
            self.inset = inset; startRadians = radians; needsLayout = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = tint.cgColor
        arc.lineWidth = lineWidth
        arc.strokeStart = trimStart
        arc.strokeEnd = trimEnd
        CATransaction.commit()
        self.rotating = rotating
        updateRotation()
    }

    private func updateRotation() {
        guard rotating, window != nil, !isHiddenOrHasHiddenAncestor else { stopRotation(); return }
        // Updating counts, theme or hover must not reset the current rotation phase.
        guard arc.animation(forKey: rotationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        let angle = (arc.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
        animation.fromValue = angle
        animation.toValue = angle + Double.pi * 2
        animation.duration = 1.2
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        arc.add(animation, forKey: rotationKey)
    }

    func stopRotation() {
        guard arc.animation(forKey: rotationKey) != nil else { return }
        let transform = arc.presentation()?.transform ?? arc.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.transform = transform
        arc.removeAnimation(forKey: rotationKey)
        CATransaction.commit()
    }
}
