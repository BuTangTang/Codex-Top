import XCTest
import Foundation
import Darwin
@testable import CodexTopCore

final class QuotaTests: XCTestCase, @unchecked Sendable {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testMultiBucketCodexOverridesLegacyAndKeepsWindowDurations() throws {
        let value = try AccountUsageProtocol.decodeResult([
            "accountId": "synthetic-account",
            "rateLimits": ["primary": ["usedPercent": 99, "windowDurationMins": 300]],
            "rateLimitsByLimitId": [
                "other": ["primary": ["usedPercent": 80, "windowDurationMins": 300]],
                "codex": ["limitId": "codex", "primary": ["usedPercent": 12.5, "windowDurationMins": 300, "resetsAt": 1_800_000_100],
                          "secondary": ["usedPercent": 61, "windowDurationMins": 10080]]
            ]
        ], at: instant)
        XCTAssertEqual(value.origin, .account)
        XCTAssertEqual(value.observedAt, instant)
        XCTAssertEqual(value.fiveHour?.usedPercent, 12.5)
        XCTAssertEqual(value.fiveHour?.remainingPercent, 88)
        XCTAssertEqual(value.fiveHour?.resetsAt, instant.addingTimeInterval(100))
        XCTAssertEqual(value.weekly?.remainingPercent, 39)
        XCTAssertNil(value.weekly?.resetsAt)
    }

    func testMissingCodexBucketAndNullQuotaAreUnavailableNotZero() {
        let values: [[String: Any]] = [
            ["rateLimitsByLimitId": [:], "rateLimits": ["primary": ["usedPercent": 1, "windowDurationMins": 300]]],
            ["rateLimitsByLimitId": ["other": ["primary": ["usedPercent": 1, "windowDurationMins": 300]]]],
            ["rateLimits": ["limitId": "other", "primary": ["usedPercent": 1, "windowDurationMins": 300]]],
            ["rateLimits": ["primary": NSNull(), "secondary": NSNull()]],
            ["rateLimits": ["primary": ["usedPercent": NSNull(), "windowDurationMins": 300]]]
        ]
        for value in values { XCTAssertThrowsError(try AccountUsageProtocol.decodeResult(value, at: instant)) }
    }

    func testLegacyUnknownDurationOverageAndInvalidWindowDoNotInventFiveHours() throws {
        let value = try AccountUsageProtocol.decodeResult([
            "rateLimitsByLimitId": NSNull(),
            "rateLimits": ["primary": ["usedPercent": 105, "windowDurationMins": 15, "resetsAt": -1],
                           "secondary": ["usedPercent": true, "windowDurationMins": 300]]
        ], at: instant)
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertEqual(value.windows[0].minutes, 15)
        XCTAssertEqual(value.windows[0].remainingPercent, 0)
        XCTAssertNil(value.windows[0].resetsAt)
        XCTAssertNil(value.fiveHour)
        XCTAssertNil(value.weekly)
        XCTAssertEqual(QuotaSnapshot(observedAt: instant, windows: []).origin, .log)
    }

    func testProtocolHandshakeDirectoryIsolationAndProcessReaping() async throws {
        let fixture = try fixture(afterInitialize: #"printf '%s\n' '{"method":"unrelated","params":{"ignored":"synthetic"}}'"# + "\n" + response)
        let client = AccountUsageClient(root: fixture.root, executableURL: fixture.executable)
        let result = try await client.snapshot()
        XCTAssertEqual(result.origin, .account)
        XCTAssertEqual(result.fiveHour?.remainingPercent, 75)
        let requests = try String(contentsOf: fixture.root.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/rateLimits/read"])
        let capturedRoot = try String(contentsOf: fixture.root.appendingPathComponent("root"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(capturedRoot, fixture.root.path)
        try assertReaped(fixture.root)
    }

    func testConcurrentRequestsAndAutomaticManualCooldowns() async throws {
        let fixture = try fixture(afterInitialize: response)
        let clock = QuotaTestClock()
        let client = AccountUsageClient(root: fixture.root, executableURL: fixture.executable, timeout: 2, clock: { clock.now })
        try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { try await client.snapshot(force: true) } }
            for try await value in group { XCTAssertEqual(value.fiveHour?.remainingPercent, 75) }
        }
        XCTAssertEqual(try attempts(fixture.root), 1)
        clock.advance(4)
        _ = try await client.snapshot(force: true)
        XCTAssertEqual(try attempts(fixture.root), 1)
        clock.advance(1)
        _ = try await client.snapshot(force: true)
        XCTAssertEqual(try attempts(fixture.root), 2)
        clock.advance(59)
        _ = try await client.snapshot()
        XCTAssertEqual(try attempts(fixture.root), 2)
        clock.advance(1)
        _ = try await client.snapshot()
        XCTAssertEqual(try attempts(fixture.root), 3)
    }

    func testBackendFailureIsRedactedAndRateLimited() async throws {
        let fixture = try fixture(afterInitialize: #"printf '%s\n' '{"id":2,"error":{"code":-1,"message":"synthetic-token-do-not-display","data":{"secret":"synthetic-secret"}}}'"#)
        let client = AccountUsageClient(root: fixture.root, executableURL: fixture.executable)
        for _ in 0..<2 {
            do { _ = try await client.snapshot(force: true); XCTFail("Expected an unavailable account") }
            catch {
                XCTAssertEqual(error as? AccountUsageClientError, .unavailable)
                XCTAssertFalse(error.localizedDescription.contains("synthetic"))
            }
        }
        XCTAssertEqual(try attempts(fixture.root), 1)
        try assertReaped(fixture.root)
    }

    func testNextAutomaticReadUsesNewAccountWithoutAnyTaskMessages() async throws {
        let fixture = try fixture(afterInitialize: #"cat "$CODEX_HOME/account-response""#)
        let responseFile = fixture.root.appendingPathComponent("account-response")
        let accountA = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300}}}}"# + "\n"
        let accountB = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}}"# + "\n"
        try accountA.write(to: responseFile, atomically: true, encoding: .utf8)
        let clock = QuotaTestClock()
        let client = AccountUsageClient(root: fixture.root, executableURL: fixture.executable, timeout: 2, clock: { clock.now })
        let first = try await client.snapshot()
        XCTAssertEqual(first.fiveHour?.remainingPercent, 10)
        try accountB.write(to: responseFile, atomically: true, encoding: .utf8)
        clock.advance(60)
        let second = try await client.snapshot()
        XCTAssertEqual(second.fiveHour?.remainingPercent, 90)
        XCTAssertEqual(try attempts(fixture.root), 2)
        let methods = try String(contentsOf: fixture.root.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            .compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, Array(repeating: ["initialize", "initialized", "account/rateLimits/read"], count: 2).flatMap { $0 })
        try assertReaped(fixture.root)
    }

    func testFailedNewAccountReadDoesNotReturnPreviousAccountSnapshot() async throws {
        let fixture = try fixture(afterInitialize: #"cat "$CODEX_HOME/account-response""#)
        let responseFile = fixture.root.appendingPathComponent("account-response")
        try (#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}"# + "\n")
            .write(to: responseFile, atomically: true, encoding: .utf8)
        let clock = QuotaTestClock()
        let client = AccountUsageClient(root: fixture.root, executableURL: fixture.executable, timeout: 2, clock: { clock.now })
        _ = try await client.snapshot()
        try (#"{"id":2,"error":{"code":-1,"message":"synthetic-signed-out"}}"# + "\n")
            .write(to: responseFile, atomically: true, encoding: .utf8)
        clock.advance(5)
        for _ in 0..<2 {
            do { _ = try await client.snapshot(force: true); XCTFail("Must not reuse account A after a failed account B read") }
            catch { XCTAssertEqual(error as? AccountUsageClientError, .unavailable) }
        }
        XCTAssertEqual(try attempts(fixture.root), 2)
        try assertReaped(fixture.root)
    }

    func testTimeoutKillsAndReapsServerThatIgnoresTerminate() async throws {
        let fixture = try fixture(afterInitialize: "trap '' TERM\nwhile :; do :; done")
        let client = AccountUsageClient(root: fixture.root, executableURL: fixture.executable, timeout: 1, clock: { ProcessInfo.processInfo.systemUptime })
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.snapshot(); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? AccountUsageClientError, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        try assertReaped(fixture.root)
    }

    func testCancellationReapsServerBeforeReturning() async throws {
        let fixture = try fixture(afterInitialize: "trap '' TERM\nwhile :; do :; done")
        let client = AccountUsageClient(root: fixture.root, executableURL: fixture.executable)
        let task = Task { try await client.snapshot() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pid").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        try assertReaped(fixture.root)
    }

    private var response: String {
        #"printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000300}}}}'"#
    }

    private func fixture(afterInitialize: String) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-top-quota-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "$CODEX_HOME/pid"
        printf '%s\\n' "$CODEX_HOME" > "$CODEX_HOME/root"
        printf 'attempt\\n' >> "$CODEX_HOME/attempts"
        IFS= read -r request
        printf '%s\\n' "$request" >> "$CODEX_HOME/requests"
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r request
        printf '%s\\n' "$request" >> "$CODEX_HOME/requests"
        IFS= read -r request
        printf '%s\\n' "$request" >> "$CODEX_HOME/requests"
        \(afterInitialize)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    private func attempts(_ root: URL) throws -> Int {
        try String(contentsOf: root.appendingPathComponent("attempts"), encoding: .utf8).split(separator: "\n").count
    }

    private func assertReaped(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text), file: file, line: line)
        XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}

private final class QuotaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
