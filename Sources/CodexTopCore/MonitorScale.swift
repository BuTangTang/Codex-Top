public enum MonitorScale {
    public static let minimum = 0.6
    public static let maximum = 1.2
    public static let step = 0.05

    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let clamped = min(maximum, max(minimum, value))
        // Integer steps per unit keep the existing 80/90/100% values stable and
        // avoid accumulating fractional error while snapping to the nearest 5%.
        let stepsPerUnit = 1 / step
        let snapped = (clamped * stepsPerUnit).rounded() / stepsPerUnit
        return min(maximum, max(minimum, snapped))
    }
}
