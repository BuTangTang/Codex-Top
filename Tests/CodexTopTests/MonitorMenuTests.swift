import AppKit
import SwiftUI
import XCTest
import CodexTopCore
@testable import CodexTop

final class MonitorMenuTests: XCTestCase {
    @MainActor
    func testMenuKeepsCompactSizeAndAllActionsAtEitherPanelScale() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(stateDirectory: directory)
        store.setPlacement(.orb)
        let presenter = MonitorMenuPresenter()
        var settingsOpened = false
        store.setScale(0.8)
        let small = presenter.makeMenu(store: store, compact: false, settings: { settingsOpened = true }, collapse: {})
        let smallSize = MonitorMenuContent.size(for: small), font = small.font
        store.setScale(1.2)
        let large = presenter.makeMenu(store: store, compact: false, settings: { settingsOpened = true }, collapse: {})
        XCTAssertEqual(large.font, font)
        XCTAssertEqual(MonitorMenuContent.size(for: large), smallSize)
        XCTAssertEqual(smallSize, CGSize(width: 208, height: 168))
        XCTAssertEqual(MonitorMenuContent.itemGroups(for: large).map(\.count), [4, 3, 1])
        XCTAssertEqual(large.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader }.count, 8)
        XCTAssertTrue(large.items.allSatisfy { $0.submenu == nil })
        XCTAssertNil(large.item(withTitle: "收回圆环"))
        let modes = large.items.filter { PanelPlacement.allCases.map(\.shortcutTitle).contains($0.title) }
        XCTAssertEqual(modes.count, 4)
        XCTAssertEqual(modes.filter { $0.state == .on }.count, 1)
        XCTAssertEqual(modes.first { $0.state == .on }?.title, PanelPlacement.orb.shortcutTitle)
        large.performActionForItem(at: large.indexOfItem(withTitle: "监控设置…"))
        XCTAssertTrue(settingsOpened)
        large.performActionForItem(at: large.indexOfItem(withTitle: "常驻浮窗"))
        XCTAssertEqual(store.placement, .floating)
        let floating = presenter.makeMenu(store: store, compact: true, settings: {}, collapse: nil)
        XCTAssertEqual(MonitorMenuContent.size(for: floating), CGSize(width: 208, height: 196))
        XCTAssertEqual(MonitorMenuContent.itemGroups(for: floating).map(\.count), [4, 3, 1, 1])
        floating.performActionForItem(at: floating.indexOfItem(withTitle: "关闭浮窗"))
        XCTAssertEqual(store.placement, .orb)
        store.setPlacement(.top)
        var collapsed = false
        let top = presenter.makeMenu(store: store, compact: false, settings: {}, collapse: { collapsed = true })
        XCTAssertEqual(MonitorMenuContent.size(for: top), CGSize(width: 208, height: 196))
        top.performActionForItem(at: top.indexOfItem(withTitle: "收起面板"))
        XCTAssertTrue(collapsed)
    }

    @MainActor
    func testMenuAppearanceAndThemeCheckmarkUseResolvedAndSavedThemes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(stateDirectory: directory)
        let presenter = MonitorMenuPresenter()
        for (choice, system, expected) in [(PanelTheme.dark, NSAppearance.Name.aqua, NSAppearance.Name.darkAqua),
                                          (.light, .darkAqua, .aqua), (.system, .darkAqua, .darkAqua), (.system, .aqua, .aqua)] {
            store.updateSystemAppearance(try XCTUnwrap(NSAppearance(named: system)))
            store.setTheme(choice)
            let menu = presenter.makeMenu(store: store, compact: false, settings: {}, collapse: {})
            XCTAssertEqual(menu.appearance?.name, expected)
            let themes = menu.items.filter { ["深色", "浅色玻璃", "跟随系统"].contains($0.title) }
            XCTAssertEqual(themes.count, 3)
            XCTAssertEqual(themes.filter { $0.state == .on }.count, 1)
            XCTAssertEqual(themes.first { $0.state == .on }?.title, choice == .system ? "跟随系统" : choice == .dark ? "深色" : "浅色玻璃")
        }
        let menu = presenter.makeMenu(store: store, compact: false, settings: {}, collapse: {})
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "深色"))
        XCTAssertEqual(store.themeChoice, .dark)
    }

    @MainActor
    func testMenuFitsVisibleScreenEvenBesideShortPanelAndScreenEdges() {
        let visible = CGRect(x: 1728, y: -236, width: 2560, height: 1353)
        let menu = CGSize(width: 208, height: 168)
        for x in [visible.minX, visible.midX, visible.midX + 0.5, visible.maxX - 324] {
            for y in [visible.minY + 10, visible.midY, visible.maxY - 72] {
                let source = CGRect(x: x, y: y, width: 324, height: 72)
                let anchor = MonitorMenuPresenter.popupOrigin(sourceFrame: source,
                                                              menuSize: menu, visible: visible)
                let frame = CGRect(x: anchor.x, y: anchor.y - menu.height, width: menu.width, height: menu.height)
                XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame))
                XCTAssertFalse(frame.intersects(source))
                if source.maxX + 8 + menu.width <= visible.maxX - 8 {
                    XCTAssertEqual(frame.minX, floor(source.maxX + 8))
                } else {
                    XCTAssertEqual(frame.maxX, floor(source.minX - 8))
                }
                if source.maxY - menu.height >= visible.minY + 8, source.maxY <= visible.maxY - 8 {
                    XCTAssertEqual(frame.maxY, floor(source.maxY))
                }
            }
        }
        let narrowScreen = CGRect(x: -640, y: -300, width: 640, height: 480)
        let origin = MonitorMenuPresenter.popupOrigin(sourceFrame: CGRect(x: -500, y: -250, width: 324, height: 72),
                                                      menuSize: menu, visible: narrowScreen)
        XCTAssertTrue(narrowScreen.insetBy(dx: 8, dy: 8).contains(CGRect(x: origin.x, y: origin.y - menu.height,
                                                                      width: menu.width, height: menu.height)))
    }

    @MainActor
    func testMenuRendersSolidBackgroundInBothThemesWithoutShowingWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(stateDirectory: directory)
        let presenter = MonitorMenuPresenter()
        for theme in [PanelTheme.dark, .light] {
            store.setTheme(theme)
            let menu = presenter.makeMenu(store: store, compact: false, settings: {}, collapse: nil)
            let size = MonitorMenuContent.size(for: menu)
            let host = NSHostingView(rootView: MonitorMenuContent(store: store, presenter: presenter, menu: menu))
            host.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["CODEX_TOP_MENU_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("menu-\(theme.rawValue).png"))
            }
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 3)?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
            if theme == .dark { XCTAssertLessThan(color.redComponent, 0.15) }
            else { XCTAssertGreaterThan(color.redComponent, 0.9) }
            XCTAssertFalse(window.isVisible)
        }
    }
}
