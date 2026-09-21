import AppKit
import SwiftUI

final class MonitorMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct MonitorMenuContent: View {
    static let width: CGFloat = 208
    static let fontSize: CGFloat = 12
    static let rowHeight: CGFloat = 28
    @ObservedObject var store: TaskStore
    @ObservedObject var presenter: MonitorMenuPresenter
    let menu: NSMenu

    static func size(for menu: NSMenu) -> CGSize {
        let actionCount = itemGroups(for: menu).dropFirst(2).flatMap { $0 }.count
        return CGSize(width: width, height: 140 + CGFloat(actionCount) * rowHeight)
    }

    // Keep the original NSMenu indices and actions while presenting its first
    // two groups as a mode grid and a theme row. Extra actions stay available.
    static func itemGroups(for menu: NSMenu) -> [[Int]] {
        var groups: [[Int]] = [[]]
        for index in menu.items.indices {
            let item = menu.items[index]
            if item.isSeparatorItem || item.isSectionHeader {
                if !groups[groups.count - 1].isEmpty { groups.append([]) }
            } else if item.action != nil {
                groups[groups.count - 1].append(index)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    var body: some View {
        let dark = store.theme == .dark
        let groups = Self.itemGroups(for: menu)
        let modes = groups.first ?? []
        let themes = groups.dropFirst().first ?? []
        let actions = groups.dropFirst(2).flatMap { $0 }
        VStack(spacing: 0) {
            Text("显示方式").font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(dark ? Color(white: 0.62) : Color(white: 0.44))
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
                .padding(.bottom, 2)
            ForEach(Array(stride(from: 0, to: modes.count, by: 2)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(Array(modes.dropFirst(start).prefix(2)), id: \.self) { index in
                        itemButton(at: index, dark: dark)
                    }
                }
            }
            HStack(spacing: 4) {
                Text("主题").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(dark ? Color(white: 0.62) : Color(white: 0.44))
                    .frame(width: 28, alignment: .leading)
                ForEach(themes, id: \.self) { index in
                    itemButton(at: index, dark: dark, theme: true)
                }
            }.padding(.top, 6)
            Rectangle().fill(dark ? Color.white.opacity(0.13) : Color.black.opacity(0.12))
                .frame(height: 1).padding(.top, 6).padding(.bottom, 5)
            ForEach(actions, id: \.self) { index in
                itemButton(at: index, dark: dark)
            }
        }
        .padding(10)
        .frame(width: Self.size(for: menu).width, height: Self.size(for: menu).height)
        .foregroundStyle(dark ? Color.white : Color(white: 0.12))
        // Solid endpoint colors, with no material or vibrancy behind the rows.
        .background(dark ? Color.black : Color(white: Palette.lightSurfaceWhite))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10), lineWidth: 0.5))
        .environment(\.colorScheme, store.theme.colorScheme)
    }

    private func itemButton(at index: Int, dark: Bool, theme: Bool = false) -> some View {
        let item = menu.items[index]
        let selected = item.state == .on
        let focused = presenter.focusedIndex == index
        let title = theme && item.title == "跟随系统" ? "系统" : item.title
        return Button { presenter.performItem(at: index) } label: {
            HStack(spacing: 6) {
                if !theme, let image = item.image {
                    Image(nsImage: image).renderingMode(.template).frame(width: 14)
                        .foregroundStyle(selected ? Color.accentColor : dark ? Color.white : Color(white: 0.12))
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: Self.fontSize, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: theme ? .center : .leading)
            .padding(.horizontal, theme ? 2 : 6).frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .background((dark ? Color.white : Color.black).opacity(focused ? 0.16 : selected ? 0.10 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityLabel(item.title)
        .accessibilityValue(selected ? "已选中" : "")
        .onHover { if $0 { presenter.focusedIndex = index } }
    }
}
