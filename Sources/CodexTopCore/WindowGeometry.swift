import Foundation
import CoreGraphics

public enum OrbExpansionDirection: Equatable, Sendable {
    case down, up
}

public enum WindowGeometry {
    /// Resolve the current button for every layout; absolute coordinates from an
    /// earlier display arrangement must not survive a temporarily missing status item.
    public static func statusPanelAnchor(provider: (() -> CGRect?)?, screenFrames: [CGRect], fallbackVisible: CGRect) -> CGRect {
        if let anchor = provider?(),
           [anchor.minX, anchor.minY, anchor.width, anchor.height].allSatisfy(\.isFinite),
           anchor.width > 0, anchor.height > 0,
           screenFrames.contains(where: { $0.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }) {
            return anchor
        }
        return CGRect(x: fallbackVisible.midX - 12, y: fallbackVisible.maxY, width: 24, height: 24)
    }
    public static func pixelAligned(_ frame: CGRect, scale: CGFloat) -> CGRect {
        let scale = scale.isFinite ? max(1, scale) : 1
        return CGRect(x: (frame.minX * scale).rounded() / scale, y: (frame.minY * scale).rounded() / scale,
                      width: max(1, (frame.width * scale).rounded()) / scale,
                      height: max(1, (frame.height * scale).rounded()) / scale)
    }
    public static func clamp(_ frame: CGRect, to visible: CGRect, inset: CGFloat = 8) -> CGRect {
        let area = visible.insetBy(dx: inset, dy: inset)
        let width = min(frame.width, max(1, area.width)), height = min(frame.height, max(1, area.height))
        return CGRect(x: min(max(frame.minX, area.minX), area.maxX - width),
                      y: min(max(frame.minY, area.minY), area.maxY - height), width: width, height: height)
    }
    /// Screen changes preserve reachable utility windows; explicit recovery uses the chosen display.
    public static func recoverUtilityWindow(_ frame: CGRect, visibleFrames: [CGRect], preferredVisible: CGRect, forcePreferred: Bool = false) -> CGRect {
        if !forcePreferred, visibleFrames.contains(where: { $0.contains(frame) }) { return frame }
        var target = preferredVisible
        if !forcePreferred {
            var largestIntersection: CGFloat = 0
            for visible in visibleFrames {
                let intersection = frame.intersection(visible)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                if area > largestIntersection { largestIntersection = area; target = visible }
            }
        }
        return clamp(frame, to: target)
    }
    public static func compact(screen: CGRect, visible: CGRect, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        if notchWidth > 0 && notchHeight > 0 {
            let width = min(screen.width, notchWidth + 176)
            return CGRect(x: screen.midX - width / 2, y: screen.maxY - notchHeight, width: width, height: notchHeight)
        }
        return clamp(CGRect(x: visible.midX - 125, y: visible.maxY - 42, width: 250, height: 34), to: visible)
    }
    /// Both top-mode endpoints share one horizontal footprint. The input size has
    /// already been scaled; the hardware camera and its side room stay in screen points.
    public static func topPanelFrames(screen: CGRect, visible: CGRect, scaledSize: CGSize, notchWidth: CGFloat, notchHeight: CGFloat) -> (compact: CGRect, expanded: CGRect) {
        let resting = compact(screen: screen, visible: visible, notchWidth: notchWidth, notchHeight: notchHeight)
        let cameraRoom = notchWidth > 0 && notchHeight > 0 ? notchWidth + 176 : 0
        let desiredWidth = max(scaledSize.width, cameraRoom)
        // A side Dock can make visibleFrame asymmetric. Keep the physical camera
        // centered, limiting both endpoints together instead of shifting only the open one.
        let availableWidth = max(1, 2 * min(resting.midX - visible.minX - 8, visible.maxX - 8 - resting.midX))
        let width = min(desiredWidth, availableWidth)
        let closed = CGRect(x: resting.midX - width / 2, y: resting.minY, width: width, height: resting.height)
        let opened = expanded(from: closed, size: CGSize(width: width, height: scaledSize.height), visible: visible)
        return (closed, opened)
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
        orbPanelLayout(from: orb, size: size, visible: visible).frame
    }

    /// Prefer growing down from the orb's top so the pointer stays near the header.
    /// Flip upward only when down cannot fit and up has more available room.
    public static func orbPanelLayout(from orb: CGRect, size: CGSize, visible: CGRect) -> (frame: CGRect, direction: OrbExpansionDirection) {
        let area = visible.insetBy(dx: 8, dy: 8)
        let downRoom = max(1, min(orb.maxY, area.maxY) - area.minY)
        let upRoom = max(1, area.maxY - max(orb.minY, area.minY))
        let direction: OrbExpansionDirection = size.height > downRoom && upRoom > downRoom ? .up : .down
        return (resizedOrbPanel(from: orb, size: size, visible: visible, direction: direction), direction)
    }

    /// Content changes preserve the selected opening edge and direction. Cap the
    /// viewport at the visible edge instead of shifting the window or flipping it.
    public static func resizedOrbPanel(from panel: CGRect, size: CGSize, visible: CGRect, direction: OrbExpansionDirection = .down) -> CGRect {
        let area = visible.insetBy(dx: 8, dy: 8)
        let width = min(max(1, size.width), max(1, area.width))
        let x = min(max(panel.midX - width / 2, area.minX), area.maxX - width)
        switch direction {
        case .down:
            let top = min(max(panel.maxY, area.minY + 1), area.maxY)
            let height = min(max(1, size.height), max(1, top - area.minY))
            return CGRect(x: x, y: top - height, width: width, height: height)
        case .up:
            let bottom = min(max(panel.minY, area.minY), area.maxY - 1)
            let height = min(max(1, size.height), max(1, area.maxY - bottom))
            return CGRect(x: x, y: bottom, width: width, height: height)
        }
    }

    /// Moving an open panel moves its return point too. A drop onto a smaller
    /// display may also resize the panel, so preserve the chosen vertical edge.
    public static func movingOrbAnchor(_ orb: CGRect, from oldPanel: CGRect, to newPanel: CGRect, direction: OrbExpansionDirection) -> CGRect {
        let dx = newPanel.minX - oldPanel.minX
        let dy = direction == .down ? newPanel.maxY - oldPanel.maxY : newPanel.minY - oldPanel.minY
        return clamp(orb.offsetBy(dx: dx, dy: dy), to: newPanel, inset: 0)
    }
}
