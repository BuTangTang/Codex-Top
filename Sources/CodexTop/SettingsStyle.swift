import SwiftUI
import CodexTopCore

/// 设置窗口的样式部件（2026-11-12 用户选设计 B：和悬浮球、面板同一种近黑 LED 风格，不放小字）。
/// 解释性文字一律放进鼠标悬停提示，界面上只留标题和数值。

/// 一张圆角卡片，里面一行一行排；行之间的细线由行自己画（第一行不画）。
struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .background(Palette.primary(scheme).opacity(scheme == .dark ? 0.045 : 0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 一行：左边标题，右边控件；`help` 放原来写在下面的说明。
struct SettingsRow<Trailing: View>: View {
    let title: String
    var divider = true
    var help: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Palette.hairline(scheme)).frame(height: 1) }
            HStack(spacing: 10) {
                Text(title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 12)
                trailing
            }
            .frame(minHeight: 44)
        }
        .help(help ?? "")
    }
}

/// 开关行。
struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var divider = true
    var help: String? = nil
    var body: some View {
        SettingsRow(title: title, divider: divider, help: help) { LEDSwitch(isOn: $isOn, label: title) }
    }
}

/// 方角点阵开关：开着时小方块亮蓝灯。
struct LEDSwitch: View {
    @Binding var isOn: Bool
    let label: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let accent = UsageCardText.blue(dark: scheme == .dark)
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 5).fill(isOn ? accent.opacity(0.28) : Palette.primary(scheme).opacity(0.12))
                RoundedRectangle(cornerRadius: 3).fill(isOn ? accent : Palette.secondary(scheme).opacity(0.75))
                    .frame(width: 12, height: 12)
                    .shadow(color: isOn ? accent.opacity(0.8) : .clear, radius: 3)
                    .padding(3)
            }
            .frame(width: 34, height: 18)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
    }
}

/// 一排选项片（代替系统分段控件）：选中的蓝底蓝框。
struct SettingsChips<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let accent = UsageCardText.blue(dark: scheme == .dark)
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Palette.primary(scheme) : Palette.secondary(scheme))
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(on ? accent.opacity(0.2) : Palette.primary(scheme).opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .overlay { if on { RoundedRectangle(cornerRadius: 7).strokeBorder(accent.opacity(0.65), lineWidth: 1) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 小按钮：浅底圆角。
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SettingsButtonBody(configuration: configuration) }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Palette.primary(scheme).opacity(configuration.isPressed ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// 显示比例：80%～120% 九格点阵条，点哪格就是哪档，当前档最亮。
struct SettingsScaleBar: View {
    @Binding var percent: Double
    @Environment(\.colorScheme) private var scheme
    private static let steps = Array(stride(from: 80, through: 120, by: 5))
    var body: some View {
        let accent = UsageCardText.blue(dark: scheme == .dark)
        let current = Int(percent.rounded())
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Self.steps, id: \.self) { step in
                    Rectangle()
                        .fill(step == current ? accent : step < current ? accent.opacity(0.55) : Palette.primary(scheme).opacity(0.12))
                        .frame(width: 18, height: 8)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { percent = Double(step) }
                        .help("\(step)%")
                }
            }
            Text("\(current)%").font(.system(size: 13, weight: .bold, design: .monospaced)).frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel("显示比例")
        .accessibilityValue("\(current)%")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 5 : direction == .decrement ? -5 : 0
            percent = Double(min(120, max(80, current + delta)))
        }
    }
}

/// 侧栏选中标记：和任务行一样的竖条小灯，选中时亮蓝。
struct SettingsPip: View {
    let on: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let color = on ? UsageCardText.blue(dark: scheme == .dark) : Palette.primary(scheme).opacity(0.2)
        VStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { _ in Rectangle().fill(color).frame(width: 4, height: 2) }
        }
        .accessibilityHidden(true)
    }
}

/// 设备读取的“最近一次局域网读取”，给设置窗口看；单独放一个小对象，免得每次读取都让面板重画。
@MainActor final class DeviceAccessMonitor: ObservableObject {
    static let shared = DeviceAccessMonitor()
    struct Read: Equatable { var host: String; var at: Date }
    @Published var lastRead: Read?
}
