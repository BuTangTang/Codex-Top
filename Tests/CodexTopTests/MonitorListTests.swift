import AppKit
import SwiftUI
import XCTest
import CSQLite
import CodexTopCore
@testable import CodexTop

final class MonitorListTests: XCTestCase {
    @MainActor
    func testFirstDisclosureCycleKeepsRunningRowGeometry() async throws {
        let fixture = try makeFixture(count: 60)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TaskStore(stateDirectory: fixture)
        await store.refresh()
        let state = MonitorPanelState()
        let host = NSHostingView(rootView: DisclosureHarness(store: store, state: state, animate: true))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 308, height: 109),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        flushLayout(host)
        try await Task.sleep(for: .milliseconds(120))
        let initial = try runningFrame(in: host)
        for expanded in [true, false, true, false] {
            withAnimation(.easeInOut(duration: 0.24)) { state.expandedFinished = expanded }
            window.setContentSize(CGSize(width: 308, height: expanded ? 217 : 109))
            for _ in 0..<6 {
                flushLayout(host)
                try await Task.sleep(for: .milliseconds(50))
                let frame = try runningFrame(in: host)
                XCTAssertEqual(frame.minX, initial.minX, accuracy: 0.5)
                XCTAssertEqual(frame.minY, initial.minY, accuracy: 0.5)
                XCTAssertEqual(frame.width, initial.width, accuracy: 0.5)
                XCTAssertEqual(frame.height, initial.height, accuracy: 0.5)
            }
        }
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func runningFrame(in host: NSView) throws -> CGRect {
        let scroll = try XCTUnwrap(findScroll(in: host))
        func findArc(_ view: NSView) -> RunningArcView? {
            if let arc = view as? RunningArcView { return arc }
            return view.subviews.compactMap { findArc($0) }.first
        }
        let arc = try XCTUnwrap(findArc(scroll))
        let frame = arc.convert(arc.bounds, to: host)
        return CGRect(x: frame.minX, y: host.isFlipped ? frame.minY : host.bounds.height - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    @MainActor
    func testOrbReopeningKeepsLongHistoryExtentAndScrollPosition() async throws {
        let fixture = try makeFixture(count: 300)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TaskStore(stateDirectory: fixture)
        await store.refresh()
        store.setPlacement(.orb)
        let orb = OrbMorphState(), panel = MonitorPanelState()
        panel.expandedFinished = true
        orb.expandedSize = CGSize(width: 307.5, height: 218.25)
        let host = NSHostingView(rootView: FloatingPanelView(store: store, presentation: PanelPresentation(),
            orbState: orb, monitorState: panel, pickTasks: {}, settings: {}, openTasks: {}, closeTasks: {},
            finishedChanged: {}, dragStarted: { _ in }, dragMoved: { _ in }, dragEnded: { _ in }).windowTypography())
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 308, height: 219),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        flushLayout(host)
        try await Task.sleep(for: .milliseconds(120))
        var durations: [Double] = []
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            withAnimation(.spring(response: 0.32, dampingFraction: 1)) {
                orb.expanded = true
                orb.surfaceFrame = CGRect(origin: .zero, size: orb.expandedSize)
            }
            flushLayout(host)
            durations.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(400))
            let scroll = try XCTUnwrap(findScroll(in: host))
            XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.height, 54 + 299 * 36, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
            orb.expanded = false
            orb.surfaceFrame = CGRect(x: 0, y: 0, width: 44, height: 44)
            flushLayout(host)
            try await Task.sleep(for: .milliseconds(80))
        }
        print("Orb opening layout, 300 synthetic tasks (ms): \(durations)")
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testDisclosureLayoutWorkWithLongHistory() async throws {
        let fixture = try makeFixture(count: 300)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TaskStore(stateDirectory: fixture)
        await store.refresh()
        let state = MonitorPanelState()
        let host = NSHostingView(rootView: DisclosureHarness(store: store, state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 308, height: 219),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        var durations: [Double] = []
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            state.expandedFinished = true
            flushLayout(host)
            durations.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(80))
            let scroll = try XCTUnwrap(findScroll(in: host))
            XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.height, 54 + 299 * 36, accuracy: 1)
            state.expandedFinished = false
            flushLayout(host)
            try await Task.sleep(for: .milliseconds(80))
        }
        print("Disclosure layout, 300 synthetic tasks (ms): \(durations)")
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func flushLayout(_ host: NSView) {
        // ObservableObject invalidation is delivered on the run loop before layout.
        for _ in 0..<3 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            host.layoutSubtreeIfNeeded()
        }
    }

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
        let fixture = try makeFixture(count: 100, activeCount: 21)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TaskStore(stateDirectory: fixture)
        await store.refresh()
        XCTAssertEqual(store.selected.count, 100)
        XCTAssertEqual(store.runningCount, 21)
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

    private func makeFixture(count: Int, activeCount: Int = 1) throws -> URL {
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
            let event = index < activeCount ? "task_started" : "task_complete"
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

private struct DisclosureHarness: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: MonitorPanelState
    var animate = false
    var body: some View {
        ScaledPanel(scale: 0.75) {
            MonitorView(store: store, compact: false, showFinished: $state.expandedFinished,
                        animationsActive: false, pickTasks: {}, settings: {})
        }.windowTypography().transaction { if !animate { $0.disablesAnimations = true } }
    }
}
