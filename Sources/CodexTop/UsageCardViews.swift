import CodexTopCore
import SwiftUI

/// 2026-11-10 用户选“A 底栏 + D1 面板里展开”，随后要求 Codex 也做一张：底栏 CX、CC 两项都能点，
/// 在底栏上方展开对应的用量卡片，同时只开一张，面板收回圆环时自动收起。数字来自本机记录里的 token 数。
enum UsageCardText {
    static func tokens(_ value: Int) -> String {
        if value >= 10_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(Int((Double(value) / 1_000).rounded()))K" }
        return "\(value)"
    }
    static func orange(dark: Bool) -> Color { dark ? Color(red: 0.94, green: 0.54, blue: 0.29) : Color(red: 0.85, green: 0.47, blue: 0.24) }
    static func blue(dark: Bool) -> Color { Color(nsColor: LEDOrbView.blue(dark: dark)) }
    static func tint(_ origin: TaskOrigin, dark: Bool) -> Color { origin == .codex ? blue(dark: dark) : orange(dark: dark) }
    static func compare(today: Int, yesterday: Int) -> String {
        guard yesterday > 0 else { return "昨天没有用量" }
        let change = Int((Double(today - yesterday) / Double(yesterday) * 100).rounded())
        return change == 0 ? "和昨天差不多" : "比昨天 \(change > 0 ? "↑" : "↓") \(abs(change))%"
    }
}

/// 底栏右边 CC 一项：小标 + “今天 1.24M”，点一下展开或收起 Claude 用量卡片。
struct ClaudeUsageButton: View {
    @ObservedObject var store: TaskStore
    var pill: Namespace.ID
    var body: some View {
        let dark = store.theme.colorScheme == .dark, open = store.openUsageCard == .claudeCode
        Button { store.toggleUsageCard(.claudeCode) } label: {
            HStack(spacing: 6) {
                SourceMark(origin: .claudeCode, scale: store.uiScale)
                Text("今天").foregroundStyle(Palette.secondary(store.theme.colorScheme))
                Text(UsageCardText.tokens(store.claudeUsage?.today.total ?? 0))
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(UsageCardText.orange(dark: dark))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 6).frame(height: 26)
            .background { UsagePill(open: open, dark: dark, namespace: pill) }
            .fixedSize().contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .help(open ? "收起 Claude 用量" : "查看 Claude 用量（按本机记录统计，走网关没有额度上限）")
        .accessibilityLabel("Claude 今天用了 \(UsageCardText.tokens(store.claudeUsage?.today.total ?? 0)) token")
    }
}

/// 底栏 CX／CC 选中时的底色，圆角和按下时一样；切换时在两个按钮之间滑过去。
struct UsagePill: View {
    let open: Bool
    let dark: Bool
    let namespace: Namespace.ID
    var body: some View {
        if open {
            RoundedRectangle(cornerRadius: 8).fill(Color(dark ? .white : .black).opacity(0.08))
                .matchedGeometryEffect(id: "usage-pill", in: namespace)
        }
    }
}

/// 展开的用量卡片：Codex 先列官方额度（有 5h 才列 5h），然后两种来源一样：今天、和昨天比、分段比例、近 7 天点阵柱。
/// 会话排行不展示（2026-11-10 用户）。高度固定，面板按它预留。
struct UsageCard: View {
    @ObservedObject var store: TaskStore
    let origin: TaskOrigin
    /// 设置“用量”页里不需要右上角的收起按钮。
    var closable = true
    static let baseHeight: CGFloat = 260
    static let quotaRow: CGFloat = 26

    /// 两张卡片一样高（2026-11-10 用户：“claude 和 codex 大小不一致”）：额度区按 Codex 的行数算，至少一行，
    /// Claude 卡片在同样的位置写“走网关，没有额度上限”。
    static func quotaRows(_ store: TaskStore) -> Int { max(1, min(2, store.quota.map { UsageText.windows($0).count } ?? 0)) }
    static func height(_ origin: TaskOrigin, store: TaskStore) -> CGFloat {
        baseHeight + CGFloat(quotaRows(store)) * quotaRow + 9
    }

    var body: some View {
        let dark = store.theme.colorScheme == .dark
        ZStack(alignment: .top) {
            UsageCardContent(store: store, origin: origin, closable: closable)
                .id(origin)
                // CX 在左、CC 在右：切到 CC 新内容从右边滑进来、旧的往左出去，切回来反过来（2026-11-11 用户要切换动画）。
                .transition(.offset(x: origin == .codex ? -36 : 36).combined(with: .opacity))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(height: Self.height(origin, store: store) - 24, alignment: .top)
        .background(Color(dark ? .white : .black).opacity(dark ? 0.05 : 0.04), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(12)
        .frame(height: Self.height(origin, store: store))
    }
}

/// 卡片里的内容，每个来源一份：每次出现（拉出卡片、CX／CC 切过来）都淡入、轻轻上浮，柱子从下往上一根根亮起
/// （2026-11-11 用户：往下展开的动画完善一下；切换时也要柱子亮起）。
private struct UsageCardContent: View {
    @ObservedObject var store: TaskStore
    let origin: TaskOrigin
    let closable: Bool
    private struct Segment { let label: String; let value: Int; let level: Double }
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(dark: store.theme.colorScheme == .dark)
            .opacity(revealed ? 1 : 0).offset(y: revealed ? 0 : 6)
            .onAppear {
                if reduceMotion { revealed = true } else { withAnimation(.easeOut(duration: 0.3).delay(0.05)) { revealed = true } }
            }
    }

    @ViewBuilder private func content(dark: Bool) -> some View {
        let tint = UsageCardText.tint(origin, dark: dark)
        // 看得清（2026-11-10 用户：“有点看不清”）：说明字用主色的七成，空格子加深，字号整体大一号。
        let secondary = Palette.primary(store.theme.colorScheme).opacity(0.72)
        let off = Color(dark ? .white : .black).opacity(0.14)
        let model = data
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SourceMark(origin: origin, scale: store.uiScale)
                Text(origin == .codex ? "Codex 用量" : "Claude 用量").font(.system(size: 13.5, weight: .bold))
                Spacer()
                if origin == .codex {
                    Button("用量网页") { store.openUsagePage() }.buttonStyle(QuietButtonStyle())
                        .font(.system(size: 12)).foregroundStyle(secondary).help("打开 Codex 官方用量网页")
                }
                if closable {
                    Button { store.toggleUsageCard(origin) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                    }.buttonStyle(QuietButtonStyle()).foregroundStyle(secondary).help("收起")
                }
            }.frame(height: 22)
            Group {
                if origin == .codex, let quota = store.quota, !UsageText.windows(quota).isEmpty {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 0) {
                            ForEach(Array(UsageText.windows(quota).prefix(2)), id: \.minutes) { window in
                                quotaRow(window, at: context.date, tint: tint, off: off, secondary: secondary)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        noteRow("额度", origin == .codex ? "暂无额度数据" : "走网关，没有额度上限", secondary: secondary)
                        if UsageCard.quotaRows(store) > 1 { noteRow("统计", "按本机 Claude Code 记录", secondary: secondary) }
                    }
                }
            }.frame(height: CGFloat(UsageCard.quotaRows(store)) * UsageCard.quotaRow, alignment: .top)
            Rectangle().fill(off).frame(height: 1).padding(.top, 4).padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageCardText.tokens(model.today)).font(.system(size: 26, weight: .heavy, design: .monospaced))
                Text("token · 今天").font(.system(size: 12.5)).foregroundStyle(secondary)
                Spacer()
                Text(UsageCardText.compare(today: model.today, yesterday: model.yesterday)).font(.system(size: 12)).foregroundStyle(secondary)
            }.frame(height: 38)
            split(model.segments, total: model.today, tint: tint, off: off).frame(height: 7).padding(.top, 4)
            // 图例几项分几栏、铺满整行（2026-11-10 用户：“右边空的，怪怪的”，选“按这个改”）：上面色块 + 说明，下面加粗的数字；
            // 第一栏靠左、最后一栏靠右、中间居中，两端和比例条对齐。
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(model.segments.enumerated()), id: \.offset) { index, segment in
                    let alignment: HorizontalAlignment = index == 0 ? .leading : index == model.segments.count - 1 ? .trailing : .center
                    VStack(alignment: alignment, spacing: 2) {
                        HStack(spacing: 4) {
                            Rectangle().fill(tint.opacity(segment.level)).frame(width: 7, height: 7)
                            Text(segment.label).font(.system(size: 12)).foregroundStyle(secondary)
                        }
                        Text(UsageCardText.tokens(segment.value)).font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
                }
            }.lineLimit(1).frame(height: 36, alignment: .top).padding(.top, 8)
            HStack {
                Text("近 7 天")
                Spacer()
                Text("合计 ").foregroundStyle(secondary) + Text(UsageCardText.tokens(model.days.reduce(0, +))).font(.system(size: 12, weight: .semibold, design: .monospaced))
            }.font(.system(size: 12)).foregroundStyle(secondary).frame(height: 24).padding(.top, 6)
            week(model.days, starts: model.starts, tint: tint, off: off, secondary: secondary).frame(height: 70)
            Spacer(minLength: 0)
        }
    }

    /// starts 是每根柱子那天的起点（两边都按本地中午 12 点切天）；空的就按本地零点倒推。
    private var data: (today: Int, yesterday: Int, days: [Int], starts: [Date], segments: [Segment]) {
        if origin == .codex {
            let usage = store.codexUsage ?? .empty, t = usage.today
            return (t.total, usage.yesterday.total, usage.days.map(\.total), usage.starts, [
                Segment(label: "输入", value: max(0, t.input - t.cached), level: 1),
                Segment(label: "缓存", value: t.cached, level: 0.32),
                Segment(label: "输出", value: max(0, t.output - t.reasoning), level: 0.7),
                Segment(label: "推理", value: t.reasoning, level: 0.5),
            ])
        }
        let usage = store.claudeUsage ?? .empty, t = usage.today
        return (t.total, usage.yesterday.total, usage.days.map(\.total), usage.starts, [
            Segment(label: "输入", value: t.input, level: 1),
            Segment(label: "输出", value: t.output, level: 0.65),
            Segment(label: "缓存读取", value: t.cacheRead, level: 0.32),
        ])
    }

    /// 一行额度：窗口名、10 格点阵、剩余百分比、什么时候重置；剩余不到三成变琥珀。
    private func quotaRow(_ window: QuotaWindow, at date: Date, tint: Color, off: Color, secondary: Color) -> some View {
        let expired = UsageText.expired(window, at: date)
        let remaining = min(100, max(0, window.remainingPercent))
        let color = remaining < 30 ? TaskPhase.waiting.tint(store.theme.colorScheme) : tint
        let lit = expired ? 0 : Int((Double(remaining) / 10).rounded())
        return HStack(spacing: 8) {
            Text(window.minutes == 10080 ? "本周" : UsageText.window(window.minutes)).foregroundStyle(secondary).frame(width: 32, alignment: .leading)
            HStack(spacing: 1) { ForEach(0..<10, id: \.self) { Rectangle().fill($0 < lit ? color : off).frame(width: 9, height: 7) } }
            Text(UsageText.remaining(window, at: date)).font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(expired ? secondary : color).frame(width: 46, alignment: .trailing)
            Spacer(minLength: 4)
            Text(reset(window, at: date)).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
        }.font(.system(size: 12.5)).frame(height: UsageCard.quotaRow)
    }

    private func noteRow(_ label: String, _ text: String, secondary: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 32, alignment: .leading)
            Text(text)
            Spacer(minLength: 0)
        }.font(.system(size: 12.5)).foregroundStyle(secondary).frame(height: UsageCard.quotaRow)
    }

    private func reset(_ window: QuotaWindow, at date: Date) -> String {
        guard let reset = window.resetsAt, reset > date else { return window.resetsAt == nil ? "" : "等待更新" }
        let minutes = Int(reset.timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(max(1, minutes)) 分钟后重置" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分后重置" }
        let weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][Calendar.current.component(.weekday, from: reset) - 1]
        return "\(weekday) \(reset.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))) 重置"
    }

    /// 70 格点阵条：有用量的每段至少 6 格，剩下的格子按占比分（缓存常占九成以上，小的几段也要看得见）。
    private func split(_ segments: [Segment], total: Int, tint: Color, off: Color) -> some View {
        let cells = 70, minimum = 6
        let used = segments.filter { $0.value > 0 }.count
        let rest = Double(max(0, cells - minimum * used))
        var bounds: [Int] = [], sum = 0
        for segment in segments {
            if segment.value > 0 { sum += minimum + Int((Double(segment.value) / Double(max(1, total)) * rest).rounded()) }
            bounds.append(min(cells, sum))
        }
        return HStack(spacing: 1) {
            ForEach(0..<cells, id: \.self) { index in
                let part = bounds.firstIndex { index < $0 }
                Rectangle().fill(total == 0 || part == nil ? off : tint.opacity(segments[part!].level)).frame(width: 3, height: 7)
            }
        }
    }

    /// 7 根 8 格的点阵柱，今天那根最亮；最高的一天和今天在柱顶写数。高度按对数算：几百万和几亿的天都看得见，差距还在。
    private func week(_ days: [Int], starts: [Date], tint: Color, off: Color, secondary: Color) -> some View {
        let peak = max(1, days.max() ?? 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return HStack(alignment: .bottom) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                let lit = day == 0 ? 0 : max(1, Int((log10(1 + Double(day) / 100_000) / log10(1 + Double(peak) / 100_000) * 8).rounded()))
                VStack(spacing: 4) {
                    Text(isToday || day == peak ? UsageCardText.tokens(day) : " ")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(isToday ? tint : secondary)
                    VStack(spacing: 1) {
                        ForEach((0..<8).reversed(), id: \.self) { row in
                            Rectangle().fill(revealed && row < lit ? (isToday ? tint : tint.opacity(0.8)) : off).frame(width: 12, height: 3)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.16).delay(0.12 + Double(index) * 0.03 + Double(row) * 0.025), value: revealed)
                        }
                    }
                    Text(isToday ? "今天" : weekday(starts.count == days.count ? starts[index]
                                                     : calendar.date(byAdding: .day, value: index - 6, to: today) ?? today, calendar))
                        .font(.system(size: 11, weight: isToday ? .bold : .medium)).foregroundStyle(isToday ? tint : secondary)
                }
                if index < days.count - 1 { Spacer(minLength: 0) }
            }
        }.padding(.horizontal, 2)
    }

    private func weekday(_ date: Date, _ calendar: Calendar) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][calendar.component(.weekday, from: date) - 1]
    }
}
