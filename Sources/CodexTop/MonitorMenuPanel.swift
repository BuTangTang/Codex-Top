import AppKit
import SwiftUI

final class MonitorMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct MonitorMenuContent: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var presenter: MonitorMenuPresenter
    let menu: NSMenu

    static func size(for menu: NSMenu) -> CGSize {
        CGSize(width: 196, height: 12 + menu.items.reduce(CGFloat.zero) {
            $0 + ($1.isSeparatorItem ? 9 : $1.isSectionHeader ? 22 : 26)
        })
    }

    var body: some View {
        let dark = store.theme == .dark
        VStack(spacing: 0) {
            ForEach(menu.items.indices, id: \.self) { index in
                let item = menu.items[index]
                if item.isSeparatorItem {
                    Rectangle().fill(dark ? Color.white.opacity(0.13) : Color.black.opacity(0.12))
                        .frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
                } else if item.isSectionHeader {
                    Text(item.title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(dark ? Color(white: 0.62) : Color(white: 0.44))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 22)
                } else {
                    Button { presenter.performItem(at: index) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                .opacity(item.state == .on ? 1 : 0).frame(width: 12)
                            if let image = item.image { Image(nsImage: image).renderingMode(.template).frame(width: 16) }
                            Text(item.title).font(.system(size: NSFont.menuFont(ofSize: 0).pointSize)).lineLimit(1)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 7).frame(height: 26)
                            .contentShape(Rectangle())
                            .background(presenter.focusedIndex == index ? Color.accentColor.opacity(dark ? 0.34 : 0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(item.state == .on ? "已选中" : "")
                    .onHover { if $0 { presenter.focusedIndex = index } }
                }
            }
        }
        .padding(6)
        .frame(width: Self.size(for: menu).width, height: Self.size(for: menu).height)
        .foregroundStyle(dark ? Color.white : Color(white: 0.12))
        // Solid endpoint colors, with no material or vibrancy behind the rows.
        .background(dark ? Color(white: 0.055) : Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dark ? Color.white.opacity(0.15) : Color.black.opacity(0.15), lineWidth: 1))
        .environment(\.colorScheme, store.theme.colorScheme)
    }
}
