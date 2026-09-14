import Foundation
import XCTest
@testable import CodexTopCore

final class TaskListPreferencesTests: XCTestCase {
    func testOlderPreferencesKeepFourVisibleRowsWithoutMigration() throws {
        let data = try JSONEncoder().encode(MonitorPreferences())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["visibleTaskCount"])
        let reloaded = try JSONDecoder().decode(MonitorPreferences.self, from: data)
        XCTAssertEqual(reloaded.resolvedVisibleTaskCount, 4)
    }

    func testVisibleRowPreferenceSurvivesModeChangesAndClampsInvalidSavedValues() throws {
        for (saved, expected) in [(Int.min, 1), (0, 1), (1, 1), (6, 6), (12, 12), (Int.max, 12)] {
            var preferences = MonitorPreferences()
            preferences.visibleTaskCount = saved
            for mode in PanelPlacement.allCases {
                preferences.setPlacement(mode)
                let reloaded = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(preferences))
                XCTAssertEqual(reloaded.resolvedVisibleTaskCount, expected)
            }
        }
    }
}
