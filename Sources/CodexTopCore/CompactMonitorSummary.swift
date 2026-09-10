import Foundation

/// Text and state for the two wings of the collapsed top presentation.
/// Quota percentages always mean remaining allowance, never consumed usage.
public struct CompactMonitorSummary: Equatable, Sendable {
    public let leftText: String
    public let leftPhase: TaskPhase
    public let quotaLines: [String]
    public let isQuotaStale: Bool

    public init(status: MonitorStatusSummary, paused: Bool, quota: QuotaSnapshot?, now: Date) {
        if status.attention > 0 {
            leftText = "\(status.attention) 待处理"
            leftPhase = status.phase
        } else if paused {
            leftText = "已暂停"
            leftPhase = .idle
        } else if status.running > 0 {
            leftText = "\(status.running) 运行中"
            leftPhase = .running
        } else {
            leftText = status.total == 0 ? "无任务" : status.phase.label
            leftPhase = status.phase
        }

        guard let quota, !quota.windows.isEmpty else {
            quotaLines = ["额度暂无数据"]
            isQuotaStale = false
            return
        }
        isQuotaStale = now.timeIntervalSince(quota.observedAt) > 300 || quota.windows.contains {
            Self.hasReset($0, at: now)
        }
        quotaLines = quota.windows.sorted { $0.minutes < $1.minutes }.prefix(2).map { window in
            let value = Self.hasReset(window, at: now) ? "待更新" : "\(window.remainingPercent)%"
            return "\(Self.period(window.minutes)) \(value)"
        }
    }

    private static func hasReset(_ window: QuotaWindow, at now: Date) -> Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }

    private static func period(_ minutes: Int) -> String {
        switch minutes {
        case 300: "5h"
        case 10080: "周"
        default: minutes.isMultiple(of: 60) ? "\(minutes / 60)h" : "\(minutes)m"
        }
    }
}
