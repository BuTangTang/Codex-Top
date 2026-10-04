import AppKit
import XCTest
import CodexTopCore
@testable import CodexTop

final class StatusItemPresentationTests: XCTestCase {
    /// 相同最终展示的多次通知不能重复写长度、图标或文案，避免触发原生布局。
    @MainActor func testRepeatedPresentationDoesNotWriteAppKitAgain() {
        let button = ObservedButton(frame: .zero)
        var renderer = StatusItemRenderer()
        var lengths: [CGFloat] = []
        let state = presentation()
        renderer.update(state, button: button) { lengths.append($0) }
        let firstWrites = button.writes
        XCTAssertGreaterThan(firstWrites, 0)

        for _ in 0..<3 { renderer.update(state, button: button) { lengths.append($0) } }

        XCTAssertEqual(lengths, [NSStatusItem.squareLength])
        XCTAssertEqual(button.writes, firstWrites)
        XCTAssertEqual(button.toolTip, "Codex Top · 2 个运行中 · 1 个待处理")
        XCTAssertEqual(button.accessibilityLabel(), button.toolTip)
    }

    /// 菜单栏文字与其他模式图标往返切换，计数、颜色、长度和读屏文本沿用原行为。
    @MainActor func testModeTransitionsKeepNativeContentsAndAccessibility() {
        let button = ObservedButton(frame: .zero)
        var renderer = StatusItemRenderer()
        var lengths: [CGFloat] = []
        renderer.update(presentation(placement: .menuBar), button: button) { lengths.append($0) }
        XCTAssertNil(button.image)
        XCTAssertEqual(button.attributedTitle.string, "  ● 2   ● 1  ")
        let text = button.attributedTitle.string as NSString
        let firstDot = text.range(of: "●").location
        let lastDot = text.range(of: "●", options: .backwards).location
        XCTAssertEqual(button.attributedTitle.attribute(.foregroundColor, at: firstDot, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual(button.attributedTitle.attribute(.foregroundColor, at: lastDot, effectiveRange: nil) as? NSColor, .systemOrange)

        for placement in [PanelPlacement.orb, .floating, .top] {
            renderer.update(presentation(placement: placement), button: button) { lengths.append($0) }
            XCTAssertNotNil(button.image)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.accessibilityLabel(), "Codex Top · 2 个运行中 · 1 个待处理")
        }
        renderer.update(presentation(placement: .menuBar, running: 0, attention: 3), button: button) { lengths.append($0) }
        XCTAssertNil(button.image)
        XCTAssertEqual(button.attributedTitle.string, "  ● 0   ● 3  ")
        XCTAssertEqual(button.toolTip, "Codex Top · 0 个运行中 · 3 个待处理")
        XCTAssertEqual(lengths, [NSStatusItem.variableLength, NSStatusItem.squareLength,
                                 NSStatusItem.squareLength, NSStatusItem.squareLength, NSStatusItem.variableLength])
    }

    /// 计数、用户主题和系统外观任一改变都可更新；零计数及外观往返也不能漏掉。
    @MainActor func testCountsAndAppearanceChangesAreAppliedBeforeDuplicatesAreSkipped() {
        let button = ObservedButton(frame: .zero)
        var renderer = StatusItemRenderer()
        var lengths: [CGFloat] = []
        let states = [presentation(), presentation(running: 0), presentation(running: 0, attention: 0),
                      presentation(running: 0, attention: 0, theme: .dark),
                      presentation(running: 0, attention: 0, theme: .dark, appearance: .darkAqua),
                      presentation(running: 0, attention: 0, theme: .dark, appearance: .accessibilityHighContrastDarkAqua),
                      presentation()]
        for (index, state) in states.enumerated() {
            renderer.update(state, button: button) { lengths.append($0) }
            let changedWrites = button.writes
            renderer.update(state, button: button) { lengths.append($0) }
            XCTAssertEqual(lengths.count, index + 1)
            XCTAssertEqual(button.writes, changedWrites)
            XCTAssertEqual(button.toolTip, "Codex Top · \(state.running) 个运行中 · \(state.attention) 个待处理")
            XCTAssertEqual(button.accessibilityLabel(), button.toolTip)
        }
    }

    /// 合成值不读取真实任务或偏好，测试按钮不挂载任何窗口或系统状态栏。
    private func presentation(placement: PanelPlacement = .orb, running: Int = 2, attention: Int = 1,
                              theme: PanelTheme = .light, appearance: NSAppearance.Name = .aqua) -> StatusItemPresentation {
        StatusItemPresentation(placement: placement, running: running, attention: attention, theme: theme, appearance: appearance)
    }
}

/// 观察真正的 NSButton 属性写入，不替换渲染逻辑或创建可见界面。
@MainActor private final class ObservedButton: NSButton {
    private(set) var writes = 0
    override var image: NSImage? { didSet { writes += 1 } }
    override var title: String { didSet { writes += 1 } }
    override var attributedTitle: NSAttributedString { didSet { writes += 1 } }
    override var toolTip: String? { didSet { writes += 1 } }
}
