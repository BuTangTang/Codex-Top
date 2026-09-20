import SwiftUI

private struct CompactMonitorTypographyKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var compactMonitorTypography: Bool {
        get { self[CompactMonitorTypographyKey.self] }
        set { self[CompactMonitorTypographyKey.self] = newValue }
    }
}

extension View {
    /// All displays use the former external-monitor typography. Keep the profile
    /// fixed from the first frame so moving between screens cannot resize text.
    func windowTypography() -> some View {
        environment(\.compactMonitorTypography, true)
    }
}
