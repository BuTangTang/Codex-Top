import XCTest
import Foundation
@testable import CodexTopCore

final class RolloutChangeMonitorTests: XCTestCase, @unchecked Sendable {
    @MainActor func testAppendNotifiesAfterRepeatedIdenticalUpdates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: root, named: "rollout.jsonl")
        let recorder = ChangeRecorder()
        let monitor = RolloutChangeMonitor { recorder.record() }
        defer { monitor.stop() }
        monitor.update(urls: [file])
        monitor.update(urls: [file])

        let changed = expectation(description: "append reported on main actor")
        recorder.next = changed
        try append(to: file)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertGreaterThan(recorder.count, 0)
        XCTAssertTrue(recorder.allCallbacksOnMainThread)
    }

    @MainActor func testRemovalAndStopSuppressQueuedEventsAndAllowRestart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: root, named: "rollout.jsonl")
        let recorder = ChangeRecorder()
        let monitor = RolloutChangeMonitor { recorder.record() }
        defer { monitor.stop() }
        monitor.update(urls: [file])

        // The main actor does not yield between writing and removing the watch,
        // so an already queued vnode event must not reach the owner afterwards.
        try append(to: file)
        monitor.update(urls: [])
        let removed = expectation(description: "removed watch remains silent")
        removed.isInverted = true
        recorder.next = removed
        try append(to: file)
        await fulfillment(of: [removed], timeout: 0.2)

        monitor.update(urls: [file])
        try append(to: file)
        monitor.stop()
        let stopped = expectation(description: "stopped watch remains silent")
        stopped.isInverted = true
        recorder.next = stopped
        try append(to: file)
        await fulfillment(of: [stopped], timeout: 0.2)

        let restarted = expectation(description: "new watch works after stop")
        recorder.next = restarted
        monitor.update(urls: [file])
        try append(to: file)
        await fulfillment(of: [restarted], timeout: 2)
    }

    @MainActor func testRenamedInodeIsDroppedAndReplacementCanBeWatched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: root, named: "rollout.jsonl")
        let moved = root.appendingPathComponent("previous.jsonl")
        let recorder = ChangeRecorder()
        let monitor = RolloutChangeMonitor { recorder.record() }
        defer { monitor.stop() }
        monitor.update(urls: [file])

        let invalidated = expectation(description: "renamed inode invalidates watch")
        recorder.next = invalidated
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("replacement\n".utf8).write(to: file)
        await fulfillment(of: [invalidated], timeout: 2)

        monitor.update(urls: [file])
        let oldInode = expectation(description: "old inode cannot signal the replacement watch")
        oldInode.isInverted = true
        recorder.next = oldInode
        try append(to: moved)
        await fulfillment(of: [oldInode], timeout: 0.2)

        let replacement = expectation(description: "replacement inode reports append")
        recorder.next = replacement
        try append(to: file)
        await fulfillment(of: [replacement], timeout: 2)
    }

    @MainActor func testReleasingMonitorDoesNotKeepWatchOrCallbackAlive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: root, named: "rollout.jsonl")
        let recorder = ChangeRecorder()
        var monitor: RolloutChangeMonitor? = RolloutChangeMonitor { recorder.record() }
        weak var released = monitor
        monitor?.update(urls: [file])
        try append(to: file)
        monitor = nil
        XCTAssertNil(released)

        let silent = expectation(description: "released monitor remains silent")
        silent.isInverted = true
        recorder.next = silent
        try append(to: file)
        await fulfillment(of: [silent], timeout: 0.2)
    }

    @MainActor func testQueuedOldInvalidationCannotRemoveANewWatchAtTheSamePath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: root, named: "rollout.jsonl")
        let moved = root.appendingPathComponent("previous.jsonl")
        let recorder = ChangeRecorder()
        let monitor = RolloutChangeMonitor { recorder.record() }
        defer { monitor.stop() }
        monitor.update(urls: [file])
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("replacement\n".utf8).write(to: file)
        // Replace the watch before the main queue can deliver the old rename.
        monitor.stop()
        monitor.update(urls: [file])
        let stale = expectation(description: "old source cannot affect the new path watch")
        stale.isInverted = true
        recorder.next = stale
        try append(to: moved)
        await fulfillment(of: [stale], timeout: 0.2)

        let replacement = expectation(description: "new watch survives old queued invalidation")
        recorder.next = replacement
        try append(to: file)
        await fulfillment(of: [replacement], timeout: 2)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexTop-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFile(in directory: URL, named name: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data("synthetic\n".utf8).write(to: file)
        return file
    }

    private func append(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed\n".utf8))
    }
}

@MainActor private final class ChangeRecorder {
    var next: XCTestExpectation?
    private(set) var count = 0
    private(set) var allCallbacksOnMainThread = true

    func record() {
        count += 1
        allCallbacksOnMainThread = allCallbacksOnMainThread && Thread.isMainThread
        // A vnode source may coalesce or split events. Positive assertions wait
        // for a change, while inverted assertions continue to catch every event.
        if let next {
            next.fulfill()
            if !next.isInverted { self.next = nil }
        }
    }
}
