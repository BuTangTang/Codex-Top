public enum MonitorScale {
    public static let minimum = 0.8
    public static let maximum = 1.2
    public static let step = 0.05
    // Displayed 100% now uses the previous 75% geometry and typography.
    public static let baseline = 0.75

    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let clamped = min(maximum, max(minimum, value))
        // Snap the displayed value, not the rendering factor, to 5% ticks.
        let stepsPerUnit = 1 / step
        let snapped = (clamped * stepsPerUnit).rounded() / stepsPerUnit
        return min(maximum, max(minimum, snapped))
    }

    public static func renderingScale(for displayScale: Double) -> Double {
        baseline * normalized(displayScale)
    }

    public static func displayScale(forRenderingScale value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return normalized(min(maximum, max(minimum, value / baseline)))
    }
}
