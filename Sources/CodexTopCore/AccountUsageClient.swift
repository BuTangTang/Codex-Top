import Foundation
import Darwin

/// One isolated, read-only account connection at a time. Create a new instance
/// when the selected Codex directory changes; caches never span directories.
public actor AccountUsageClient {
    private let root: URL
    private let executableURL: URL?
    private let timeout: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var lastAttempt: TimeInterval?
    private var cached: Result<QuotaSnapshot, AccountUsageClientError>?
    private var pending: (id: UUID, task: Task<QuotaSnapshot, Error>)?

    public init(root: URL, executableURL: URL? = nil) {
        self.root = root.standardizedFileURL
        self.executableURL = executableURL
        self.timeout = 15
        self.clock = { ProcessInfo.processInfo.systemUptime }
    }

    // An injected monotonic clock and deadline make cooldown/process cleanup
    // testable without real accounts, wall-clock changes or minute-long sleeps.
    init(root: URL, executableURL: URL, timeout: TimeInterval, clock: @escaping @Sendable () -> TimeInterval) {
        self.root = root; self.executableURL = executableURL
        self.timeout = max(0.05, timeout); self.clock = clock
    }

    /// Automatic reads are at least 60 seconds apart; forced reads at least 5.
    /// Concurrent callers share a connection. Cancelling a caller cancels it for
    /// all waiters; only this client's owned CLI process is stopped.
    public func snapshot(force: Bool = false) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        if let pending { return try await wait(for: pending.task) }
        let now = clock()
        if let lastAttempt, now - lastAttempt < (force ? 5 : 60) {
            guard let cached else { throw AccountUsageClientError.unavailable }
            return try cached.get()
        }
        lastAttempt = now
        let request = AccountUsageProcess(root: root, executableURL: executableURL ?? Self.findExecutable(), timeout: timeout)
        let id = UUID()
        let task = Task { try await request.snapshot() }
        pending = (id, task)
        do {
            let value = try await wait(for: task)
            if pending?.id == id { cached = .success(value); pending = nil }
            return value
        } catch {
            if pending?.id == id {
                pending = nil
                if !(error is CancellationError) { cached = .failure(error as? AccountUsageClientError ?? .unavailable) }
            }
            throw error
        }
    }

    public func cancel() { pending?.task.cancel() }

    private func wait(for task: Task<QuotaSnapshot, Error>) async throws -> QuotaSnapshot {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func findExecutable() -> URL? {
        let manager = FileManager.default
        var candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        return candidates.first(where: manager.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }
}

private final class AccountUsageProcess: @unchecked Sendable {
    private let root: URL
    private let executableURL: URL?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false

    init(root: URL, executableURL: URL?, timeout: TimeInterval) {
        self.root = root; self.executableURL = executableURL; self.timeout = timeout
    }

    func snapshot() async throws -> QuotaSnapshot {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    // run() reaps the process before its result reaches callers.
                    continuation.resume(with: Result { try self.run() })
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
        }
    }

    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    private func run() throws -> QuotaSnapshot {
        try checkCancellation()
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AccountUsageClientError.cliUnavailable
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = root.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Do not retain backend diagnostics or allow an unread stderr pipe to fill.
        process.standardError = FileHandle.nullDevice
        let startedAt = ProcessInfo.processInfo.systemUptime
        do { try process.run() } catch { throw AccountUsageClientError.unavailable }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let writer = input.fileHandleForWriting, reader = output.fileHandleForReading
        // A server exit between a response and the next small write must be an
        // ordinary read failure, not SIGPIPE terminating the monitoring app.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            try? writer.close()
            if process.isRunning { process.terminate() }
            let grace = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? reader.close()
        }
        func send(_ data: Data) throws {
            do { try writer.write(contentsOf: data) } catch { throw AccountUsageClientError.unavailable }
        }
        try send(AccountUsageProtocol.initialize)
        var initialized = false, buffer = Data(), bytesRead = 0
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            try checkCancellation()
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - startedAt)
            guard remaining > 0 else { throw AccountUsageClientError.timedOut }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(50, max(1, remaining * 1000))))
            if ready < 0 { if errno == EINTR { continue }; throw AccountUsageClientError.unavailable }
            if ready == 0 { continue }
            let count = Darwin.read(reader.fileDescriptor, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue }; throw AccountUsageClientError.unavailable }
            guard count > 0 else { throw AccountUsageClientError.unavailable }
            bytesRead += count
            guard bytesRead <= 1_048_576 else { throw AccountUsageClientError.invalidResponse }
            buffer.append(contentsOf: chunk.prefix(count))
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard !line.isEmpty else { continue }
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw AccountUsageClientError.invalidResponse
                }
                guard message["method"] == nil, let id = message["id"] as? Int else { continue }
                if id == 1 && !initialized {
                    guard message["error"] == nil, message["result"] is [String: Any] else { throw AccountUsageClientError.unavailable }
                    initialized = true
                    try send(AccountUsageProtocol.read)
                } else if id == 2 && initialized {
                    guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                        throw AccountUsageClientError.unavailable
                    }
                    try checkCancellation()
                    return try AccountUsageProtocol.decodeResult(result, at: .now)
                }
            }
        }
    }
}
