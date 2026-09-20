import AppKit
import XCTest
import CodexTopCore
@testable import CodexTop

final class SystemThemeTests: XCTestCase {
    @MainActor
    func testAutomaticChoicePersistsAndManualChoiceOverridesSystemChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(stateDirectory: directory)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(store.themeChoice, .dark) // Legacy preference remains dark.
        store.updateSystemAppearance(light)
        XCTAssertEqual(store.theme, .dark)
        store.setTheme(.system)
        XCTAssertEqual(store.theme, .light)
        store.updateSystemAppearance(dark)
        XCTAssertEqual(store.theme, .dark)
        XCTAssertEqual(store.themeChoice, .system)
        XCTAssertEqual(TaskStore(stateDirectory: directory).themeChoice, .system)
        // Selecting dark when automatic currently resolves dark must still save
        // the manual choice, so the next light event does not change it.
        store.setTheme(.dark)
        store.updateSystemAppearance(light)
        XCTAssertEqual(store.themeChoice, .dark)
        XCTAssertEqual(store.theme, .dark)
        store.setTheme(.light)
        store.updateSystemAppearance(dark)
        XCTAssertEqual(store.theme, .light)
        XCTAssertEqual(TaskStore(stateDirectory: directory).themeChoice, .light)
    }

    @MainActor
    func testNativeAppearanceObservationUpdatesWithoutTaskRefresh() async throws {
        let application = NSApplication.shared
        let original = application.appearance
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        application.appearance = NSAppearance(named: .aqua)
        let store = TaskStore(stateDirectory: directory)
        defer {
            store.stop()
            application.appearance = original
            try? FileManager.default.removeItem(at: directory)
        }
        store.setTheme(.system)
        store.startObservingAppearance() // No task source or quota requests start.
        application.appearance = NSAppearance(named: .darkAqua)
        let dark = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { store.theme == .dark }
        }, object: nil)
        await fulfillment(of: [dark], timeout: 2)
        application.appearance = NSAppearance(named: .aqua)
        let light = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { store.theme == .light }
        }, object: nil)
        await fulfillment(of: [light], timeout: 2)
        XCTAssertTrue(store.loading)
        XCTAssertNil(store.lastRefresh)
    }
}
