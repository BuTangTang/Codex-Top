import AppKit
import SwiftUI
import XCTest
import CSQLite
import CodexTopCore
@testable import CodexTop

final class MonitorListTests: XCTestCase {
    @MainActor
    func testRemovalPersistsAcrossRefreshAndRestartAndCanBeReadded() async throws {
        let fixture = try makeFixture(count: 6)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("state_5.sqlite")
        let before = try Data(contentsOf: database)
        let store = TaskStore(stateDirectory: fixture)
        await store.refresh()
        store.removeFromMonitoring("synthetic-1")
        XCTAssertEqual(store.selected.count, 5)
        XCTAssertTrue(store.preferences.excludedIDs.contains("synthetic-1"))
        await store.refresh()
        XCTAssertEqual(store.selected.count, 5)
        let restarted = TaskStore(stateDirectory: fixture)
        await restarted.refresh()
        XCTAssertEqual(restarted.selected.count, 5)
        let original = restarted.preferences.selectedIDs
        restarted.applySelection(original.union(["synthetic-1"]), original: original)
        await restarted.refresh()
        XCTAssertEqual(restarted.selected.count, 6)
        XCTAssertFalse(restarted.preferences.excludedIDs.contains("synthetic-1"))
        XCTAssertEqual(try Data(contentsOf: database), before, "Monitoring must not change source tasks")
    }

    @MainActor
    func testBatchDeselectOnlyRemovesFilteredFinishedTasks() async throws {
        let fixture = try makeFixture(count: 6)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TaskStore(stateDirectory: fixture)
        await store.refresh()
        let original = store.preferences.selectedIDs
        // The picker owns the draft; filtering and deselection do not save it.
        var draft = original
        draft.subtract(store.finished.map(\.id))
        XCTAssertEqual(store.preferences.selectedIDs, original)
        store.applySelection(draft, original: original)
        await store.refresh()
        XCTAssertEqual(store.preferences.selectedIDs, ["synthetic-0"])
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertEqual(store.preferences.excludedIDs.count, 5)
        let restarted = TaskStore(stateDirectory: fixture)
        await restarted.refresh()
        XCTAssertEqual(restarted.preferences.selectedIDs, ["synthetic-0"])
    }

    @MainActor
    func testMixedHeightListKeepsItsExtentWhileScrolling() async throws {
        let fixture = try makeFixture(count: 100)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TaskStore(stateDirectory: fixture)
        await store.refresh()
        XCTAssertEqual(store.selected.count, 100)
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertNil(store.sourceWarning)
        let root = ScaledPanel(scale: 0.75) {
            MonitorView(store: store, compact: false, showFinished: .constant(true),
                        animationsActive: false, pickTasks: {}, settings: {})
        }.windowTypography().transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 308, height: 219),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let scroll = try XCTUnwrap(findScroll(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        let initial = document.frame.height
        var heights = [initial]
        for fraction in [0.4, 0.95, 0.2, 0.7, 0.0] {
            let target = max(0, document.frame.height - scroll.contentView.bounds.height) * fraction
            scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            heights.append(document.frame.height)
        }
        XCTAssertGreaterThan(initial, 2000)
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 1,
                                 "Scrolling must not replace estimated row heights: \(heights)")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertFalse(window.isVisible, "Synthetic tests must never open a desktop window")
    }

    @MainActor private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { findScroll(in: $0) }.first
    }

    private func makeFixture(count: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)", nil, nil, nil), SQLITE_OK)
        let now = Date(), stamp = ISO8601DateFormatter().string(from: Date())
        var preferences = MonitorPreferences()
        preferences.initialized = true
        preferences.autoMonitor = true
        preferences.autoEnabledAt = now.addingTimeInterval(-60)
        preferences.autoBaselineIDs = []
        preferences.codexHome = directory.path
        preferences.uiScale = 0.75
        preferences.theme = .light
        for index in 0..<count {
            let id = "synthetic-\(index)", log = directory.appendingPathComponent("\(index).jsonl")
            let event = index == 0 ? "task_started" : "task_complete"
            let record: [String: Any] = ["type": "event_msg", "timestamp": stamp,
                                       "payload": ["type": event, "turn_id": "synthetic-turn"]]
            var data = try JSONSerialization.data(withJSONObject: record)
            data.append(10)
            try data.write(to: log)
            let sql = "INSERT INTO threads VALUES('\(id)','合成任务 \(index)','/synthetic','\(log.path)',\(Int(now.timeIntervalSince1970)),\(Int(now.timeIntervalSince1970) - index),0)"
            XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
            preferences.selectedIDs.insert(id)
        }
        try PreferencesFile(url: directory.appendingPathComponent("preferences.json")).save(preferences)
        return directory
    }
}
