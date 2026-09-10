import SwiftUI
import CodexTopCore

private enum UsageText {
    static func window(_ minutes: Int) -> String {
        switch minutes {
        case 300: "5h"
        case 10080: "周"
        default: minutes.isMultiple(of: 60) ? "\(minutes / 60)h" : "\(minutes)m"
        }
    }
    static func expired(_ window: QuotaWindow, at date: Date) -> Bool {
        window.resetsAt.map { $0 <= date } ?? false
    }
    static func remaining(_ window: QuotaWindow, at date: Date) -> String {
        expired(window, at: date) ? "待更新" : "\(window.remainingPercent)%"
    }
    static func windows(_ quota: QuotaSnapshot) -> [QuotaWindow] {
        quota.windows.sorted { $0.minutes < $1.minutes }
    }
    static func summary(_ quota: QuotaSnapshot, at date: Date) -> String {
        "剩余 " + windows(quota).prefix(2).map { "\(window($0.minutes)) \(remaining($0, at: date))" }.joined(separator: " · ")
    }
    static func historical(_ quota: QuotaSnapshot, at date: Date) -> Bool {
        date.timeIntervalSince(quota.observedAt) > 300 || quota.windows.contains { expired($0, at: date) }
    }
    static func details(_ quota: QuotaSnapshot, at date: Date) -> String {
        let values = windows(quota).map { value in
            let reset = value.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "暂无重置时间"
            return "\(window(value.minutes)) 剩余 \(remaining(value, at: date)) · 重置：\(reset)"
        }
        let source = quota.origin == .account ? "账户额度" : "日志中的额度"
        let missing = quota.fiveHour == nil ? ["5h 额度：暂无数据"] : []
        return ([source] + values + missing + ["更新于 \(quota.observedAt.formatted(date: .abbreviated, time: .standard))"]).joined(separator: "\n")
    }
}

struct UsageSummaryButton: View {
    @ObservedObject var store: TaskStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Button { store.openUsagePage() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 14))
                    if let quota = store.quota {
                        Text(UsageText.summary(quota, at: context.date)).monospacedDigit()
                        if UsageText.historical(quota, at: context.date) || store.quotaWarning != nil {
                            Image(systemName: "clock").foregroundStyle(TaskPhase.waiting.tint(store.theme.colorScheme))
                        }
                    } else {
                        Text(store.demo ? "演示模式 · 查看用量" : store.quotaRefreshing ? "正在读取额度…" : "额度暂无数据")
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .help(tooltip(at: context.date))
            .accessibilityLabel("Codex 额度，打开官方用量网页")
            .accessibilityValue(store.quota.map { UsageText.details($0, at: context.date) } ?? "额度暂无数据")
            .contextMenu {
                Button("打开 Codex 用量网页") { store.openUsagePage() }
                Button("刷新额度") { store.refreshQuota(force: true) }.disabled(store.demo || store.quotaRefreshing)
            }
        }
    }
    private func tooltip(at date: Date) -> String {
        let value = store.quota.map { UsageText.details($0, at: date) }
            ?? (store.demo ? "演示模式不读取真实账户额度。" : "等待账户额度，或打开官方用量页面查看。")
        return value + (store.quotaWarning.map { "\n" + $0 } ?? "") + "\n点击打开 Codex 官方用量网页"
    }
}

struct UsageSettingsContent: View {
    @ObservedObject var store: TaskStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let quota = store.quota {
                ForEach(UsageText.windows(quota), id: \.minutes) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(UsageText.window(window.minutes)) 额度")
                            Spacer()
                            Text("剩余 \(UsageText.remaining(window, at: context.date))").monospacedDigit()
                        }
                        if let reset = window.resetsAt {
                            Text("重置：\(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("\(quota.origin == .account ? "账户额度" : "日志记录") · 更新于 \(quota.observedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if quota.fiveHour == nil { Text("5h 额度：暂无数据").font(.caption).foregroundStyle(.secondary) }
                if UsageText.historical(quota, at: context.date) { Text("这是最近一次记录，等待最新额度。").font(.caption).foregroundStyle(.orange) }
            } else {
                Text(store.demo ? "演示模式不读取真实账户额度。" : store.quotaRefreshing ? "正在读取账户额度…" : "暂时没有额度数据，请确认 Codex 已登录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let warning = store.quotaWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
        HStack {
            Button("刷新额度") { store.refreshQuota(force: true) }.disabled(store.demo || store.quotaRefreshing)
            Spacer()
            Button("打开官方用量网页") { store.openUsagePage() }
        }
    }
}
