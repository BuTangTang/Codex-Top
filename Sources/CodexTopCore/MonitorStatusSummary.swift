import Foundation

/// Preserve simultaneous running and attention signals in compact presentations.
public struct MonitorStatusSummary: Equatable, Sendable {
    public let total: Int
    public let running: Int
    public let waiting: Int
    public let failed: Int
    public let phase: TaskPhase
    public var attention: Int { waiting + failed }

    public init(phases: [TaskPhase]) {
        total = phases.count
        running = phases.filter { $0 == .running }.count
        waiting = phases.filter { $0 == .waiting }.count
        failed = phases.filter { $0 == .failed }.count
        if failed > 0 { phase = .failed }
        else if waiting > 0 { phase = .waiting }
        else if running > 0 { phase = .running }
        else if phases.contains(.unknown) { phase = .unknown }
        else if phases.contains(.idle) || phases.isEmpty { phase = .idle }
        else if phases.allSatisfy({ $0 == .completed }) { phase = .completed }
        else { phase = .stopped }
    }
}
