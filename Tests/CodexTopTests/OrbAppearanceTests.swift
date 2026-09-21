import AppKit
import XCTest
import CodexTopCore
import CSQLite
@testable import CodexTop

final class OrbAppearanceTests: XCTestCase {
    @MainActor
    func testRetiredAndFutureAppearanceValuesKeepAllOtherPreferencesAndRemainWritable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")
        var preferences = MonitorPreferences()
        preferences.selectedIDs = ["synthetic-selected"]
        preferences.excludedIDs = ["synthetic-excluded"]
        preferences.initialized = true
        preferences.autoMonitor = false
        preferences.autoBaselineIDs = ["synthetic-baseline"]
        preferences.automaticallyRemovedIDs = ["synthetic-retired"]
        preferences.retentionProtectedIDs = ["synthetic-protected"]
        preferences.setPlacement(.orb)
        preferences.floatingReturnPlacement = .menuBar
        preferences.floatingX = 0.37; preferences.floatingY = 0.64
        preferences.floatingDisplay = "synthetic-display"
        preferences.theme = .light
        preferences.uiScale = 0.7875
        preferences.visibleTaskCount = 5
        preferences.finishedRetentionDays = 3
        for (raw, expected) in [("robot", OrbAppearance.twinArc), ("future-appearance", .ring)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
            object["orbAppearance"] = raw
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let store = TaskStore(stateDirectory: directory)
            defer { store.stop() }
            var expectedPreferences = preferences
            expectedPreferences.orbAppearance = expected
            XCTAssertNil(store.notice)
            XCTAssertEqual(store.preferences, expectedPreferences)
            XCTAssertEqual(store.orbAppearance, expected)
            store.setOrbAppearance(expected == .ring ? .twinArc : .ring)
            expectedPreferences.orbAppearance = expected == .ring ? .twinArc : .ring
            XCTAssertEqual(try PreferencesFile(url: url).load(), expectedPreferences)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(saved["orbAppearance"] as? String, expectedPreferences.orbAppearance?.rawValue)
        }
        XCTAssertEqual(OrbAppearance.allCases, [.ring, .twinArc])
    }

    @MainActor
    func testUnmonitoredMissingHistoryDoesNotHideValidOrbStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)", nil, nil, nil), SQLITE_OK)
        let now = Date(), log = directory.appendingPathComponent("active.jsonl")
        func record(_ event: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
                "payload": ["type": event, "turn_id": "synthetic-turn"]])
            data.append(10)
            return data
        }
        let start = try record("task_started")
        try start.write(to: log)
        for (id, file) in [("active", log), ("missing", directory.appendingPathComponent("missing.jsonl"))] {
            let sql = "INSERT INTO threads VALUES('\(id)','Synthetic','/synthetic','\(file.path)',\(Int(now.timeIntervalSince1970)),\(Int(now.timeIntervalSince1970)),0)"
            XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
        }
        var preferences = MonitorPreferences()
        preferences.initialized = true; preferences.autoMonitor = false
        preferences.codexHome = directory.path; preferences.selectedIDs = ["active"]
        try PreferencesFile(url: directory.appendingPathComponent("preferences.json")).save(preferences)
        let store = TaskStore(stateDirectory: directory)
        defer { store.stop() }
        await store.refresh()
        XCTAssertNotNil(store.sourceWarning)
        XCTAssertEqual(store.orbPhase, .running)
        XCTAssertEqual(store.orbStatusLabel, "运行中")
        try (start + record("task_complete")).write(to: log)
        await store.refresh()
        XCTAssertEqual(store.orbPhase, .completed)
        store.applySelection(["active", "missing"], original: ["active"])
        XCTAssertEqual(store.orbPhase, .unknown, "A monitored missing record must prevent an all-completed appearance")
    }

    @MainActor
    func testUnavailableEmptySourceDoesNotLookIdle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var preferences = MonitorPreferences()
        preferences.codexHome = directory.path
        try PreferencesFile(url: directory.appendingPathComponent("preferences.json")).save(preferences)
        let store = TaskStore(stateDirectory: directory)
        defer { store.stop() }
        await store.refresh()
        XCTAssertNotNil(store.sourceWarning)
        XCTAssertEqual(store.orbPhase, .unknown)
        XCTAssertEqual(store.orbStatusLabel, "任务状态暂时无法更新")
    }

    func testLegacyPreferencesKeepRingAndBothAppearancesSurviveModeChanges() throws {
        var preferences = MonitorPreferences()
        preferences.selectedIDs = ["synthetic-task"]
        preferences.excludedIDs = ["synthetic-exclusion"]
        preferences.theme = .light
        preferences.uiScale = 0.7875
        let legacy = try JSONEncoder().encode(preferences)
        XCTAssertNil((try JSONSerialization.jsonObject(with: legacy) as? [String: Any])?["orbAppearance"])
        XCTAssertEqual(try JSONDecoder().decode(MonitorPreferences.self, from: legacy).resolvedOrbAppearance, .ring)
        for appearance in OrbAppearance.allCases {
            preferences.orbAppearance = appearance
            for mode in PanelPlacement.allCases {
                preferences.setPlacement(mode)
                let restored = try JSONDecoder().decode(MonitorPreferences.self, from: JSONEncoder().encode(preferences))
                XCTAssertEqual(restored.resolvedOrbAppearance, appearance)
                XCTAssertEqual(restored.resolvedPlacement, mode)
                XCTAssertEqual(restored.selectedIDs, ["synthetic-task"])
                XCTAssertEqual(restored.excludedIDs, ["synthetic-exclusion"])
                XCTAssertEqual(restored.theme, .light)
                XCTAssertEqual(restored.uiScale, 0.7875)
            }
        }
    }

    @MainActor
    func testAppearanceSelectionPersistsWithoutRequestingWindowGeometryOrModeChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(stateDirectory: directory)
        store.setPlacement(.orb)
        store.setTheme(.light)
        store.setScale(1.05)
        let before = store.preferences
        var geometryChanges = 0, modeChanges = 0
        store.onChange = { geometryChanges += 1 }
        store.onModeChange = { modeChanges += 1 }
        for appearance in [OrbAppearance.twinArc, .ring, .twinArc] {
            store.setOrbAppearance(appearance)
            let restored = TaskStore(stateDirectory: directory)
            XCTAssertEqual(restored.orbAppearance, appearance)
            var expected = before
            expected.orbAppearance = appearance
            XCTAssertEqual(restored.preferences, expected)
        }
        XCTAssertEqual(geometryChanges, 0)
        XCTAssertEqual(modeChanges, 0)
        XCTAssertEqual(store.orbPhase, .unknown)
        XCTAssertEqual(store.orbStatusLabel, "正在读取任务状态")
        store.paused = true
        XCTAssertEqual(store.orbPhase, .unknown)
        XCTAssertEqual(store.orbStatusLabel, "任务刷新已暂停")
        store.stop()
    }
}
