import Foundation
import XCTest
@testable import CodexTopCore

final class PlacementHistoryTests: XCTestCase {
    func testUnpinReturnsToEveryOriginAfterSavingAndReloadingPreferences() throws {
        for origin in [PanelPlacement.top, .orb, .menuBar] {
            var preferences = MonitorPreferences()
            preferences.selectedIDs = ["selected"]
            preferences.excludedIDs = ["excluded"]
            preferences.setPlacement(origin)
            preferences.setPlacement(.floating)
            XCTAssertEqual(preferences.resolvedPlacement, .floating)
            XCTAssertTrue(preferences.floating)

            var reloaded = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(reloaded.resolvedUnpinnedPlacement, origin)
            reloaded.setPlacement(reloaded.resolvedUnpinnedPlacement)
            XCTAssertEqual(reloaded.resolvedPlacement, origin)
            XCTAssertFalse(reloaded.floating)
            XCTAssertEqual(reloaded.selectedIDs, ["selected"])
            XCTAssertEqual(reloaded.excludedIDs, ["excluded"])
        }
    }

    func testRepeatedPinPreservesOriginAndNextPinRemembersNewMode() {
        var preferences = MonitorPreferences()
        preferences.setPlacement(.orb)
        preferences.setPlacement(.floating)
        preferences.setPlacement(.floating)
        XCTAssertEqual(preferences.resolvedUnpinnedPlacement, .orb)

        // An explicit menu choice wins immediately; the next pin uses that choice.
        preferences.setPlacement(.menuBar)
        XCTAssertEqual(preferences.resolvedPlacement, .menuBar)
        preferences.setPlacement(.floating)
        XCTAssertEqual(preferences.resolvedUnpinnedPlacement, .menuBar)
        preferences.setPlacement(preferences.resolvedUnpinnedPlacement)
        XCTAssertEqual(preferences.resolvedPlacement, .menuBar)
    }

    func testOlderPreferencesAndFloatingReturnTargetFallBackToTop() throws {
        var old = MonitorPreferences()
        old.floating = true
        let data = try JSONEncoder().encode(old)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["floatingReturnPlacement"], "Older files have no remembered origin")
        var reloaded = try JSONDecoder().decode(MonitorPreferences.self, from: data)
        XCTAssertEqual(reloaded.resolvedPlacement, .floating)
        XCTAssertEqual(reloaded.resolvedUnpinnedPlacement, .top)
        reloaded.floatingReturnPlacement = .floating
        XCTAssertEqual(reloaded.resolvedUnpinnedPlacement, .top, "Unpinning must not lead back to the pinned mode")
    }
}
