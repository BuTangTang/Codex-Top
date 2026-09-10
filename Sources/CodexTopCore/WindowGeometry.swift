import Foundation
import CoreGraphics

public enum WindowGeometry {
    public static func clamp(_ frame: CGRect, to visible: CGRect, inset: CGFloat = 8) -> CGRect {
        let area = visible.insetBy(dx: inset, dy: inset)
        let width = min(frame.width, max(1, area.width)), height = min(frame.height, max(1, area.height))
        return CGRect(x: min(max(frame.minX, area.minX), area.maxX - width),
                      y: min(max(frame.minY, area.minY), area.maxY - height), width: width, height: height)
    }
    public static func compact(screen: CGRect, visible: CGRect, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        if notchWidth > 0 && notchHeight > 0 {
            let width = min(screen.width, notchWidth + 196)
            return CGRect(x: screen.midX - width / 2, y: screen.maxY - notchHeight, width: width, height: notchHeight)
        }
        return clamp(CGRect(x: visible.midX - 125, y: visible.maxY - 42, width: 250, height: 34), to: visible)
    }
    public static func floating(size: CGSize, visible: CGRect, x: Double, y: Double) -> CGRect {
        let availableX = max(0, visible.width - size.width), availableY = max(0, visible.height - size.height)
        let safeX = x.isFinite ? min(1, max(0, x)) : 0.7
        let safeY = y.isFinite ? min(1, max(0, y)) : 0.7
        return clamp(CGRect(x: visible.minX + availableX * safeX, y: visible.minY + availableY * safeY, width: size.width, height: size.height), to: visible)
    }
    /// The open surface grows from the same top edge, including above visibleFrame on a notched display.
    public static func expanded(from compact: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let width = min(max(1, size.width), max(1, visible.width - 16))
        let height = min(max(compact.height, size.height), max(1, compact.maxY - visible.minY - 8))
        let x = min(max(compact.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        return CGRect(x: x, y: compact.maxY - height, width: width, height: height)
    }

    public static func expandedOrb(from orb: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        clamp(CGRect(x: orb.midX - size.width / 2, y: orb.midY - size.height / 2, width: size.width, height: size.height), to: visible)
    }

    public static func shouldDock(_ frame: CGRect, to visible: CGRect, distance: CGFloat = 24) -> Bool {
        frame.midX >= visible.minX && frame.midX <= visible.maxX && frame.maxY >= visible.maxY - distance && frame.maxY <= visible.maxY + 64
    }
}
