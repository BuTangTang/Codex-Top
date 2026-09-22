import Foundation
import Darwin
import XCTest
import CSQLite
@testable import CodexTopCore

final class DesktopReplyReceiptSourceTests: XCTestCase {
    private let thread = "00000000-0000-4000-8000-000000000001"
    private let turn = "00000000-0000-4000-8000-000000000002"
    private let reply = "00000000-0000-4000-8000-000000000003"
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    /// 构造真实问题卡片包装，全部文本为固定合成内容。
    private func message() throws -> String {
        let key = String(decoding: try JSONSerialization.data(withJSONObject: ["request_user_input_async", "call_synthetic", 0]), as: UTF8.self)
        let answer = try JSONSerialization.data(withJSONObject: [["questionItemId": key, "question": "合成问题", "answer": "合成回答"]])
        return "<send_user_message_question_reply>\n\(String(decoding: answer, as: UTF8.self))\n</send_user_message_question_reply>"
    }

    /// 构造桌面已答项，可按用例覆盖直接字段以验证严格匹配。
    private func item(status: String = "accepted", overrides: [String: Any] = [:]) throws -> [String: Any] {
        var value: [String: Any] = ["type": "steeringUserMessage", "id": "synthetic-local-item",
                                    "status": status, "targetTurnId": turn, "clientUserMessageId": reply,
                                    "input": [["type": "text", "text": try message(), "text_elements": []]],
                                    "restoreMessage": ["id": reply, "createdAt": started.addingTimeInterval(20).timeIntervalSince1970 * 1_000]]
        for (key, entry) in overrides { value[key] = entry }
        return value
    }

    /// 构造真实 canonical 容器路径，防止测试误用简化的顶层 items。
    private func state(items: [[String: Any]], threadID: String? = nil, turnID: String? = nil,
                       status: String = "inProgress", canonical: Bool = true) -> [String: Any] {
        let value: [String: Any] = ["turnId": turnID ?? turn, "status": status, "items": items]
        if !canonical { return ["id": threadID ?? thread, "hostId": "local", "turns": [value], "turnHistory": ["kind": "legacy"]] }
        return ["id": threadID ?? thread, "hostId": "local", "turns": [],
                "turnHistory": ["kind": "canonical", "history": ["islands": [["entries": [["value": "entity-one"]]]],
                                                                    "entitiesByKey": ["entity-one": value]]]]
    }

    /// 生成版本化 snapshot 广播，不包含任何真实任务正文。
    private func snapshot(_ state: [String: Any], version: Any = 11, envelopeThread: String? = nil,
                          host: String = "local") throws -> Data {
        try framed(["type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": "synthetic-owner",
                    "version": version, "params": ["hostId": host, "conversationId": envelopeThread ?? thread,
                                                     "change": ["type": "snapshot", "revision": 1, "conversationState": state]]])
    }

    /// 将合成消息编码为桌面实际使用的小端长度帧。
    private func framed(_ value: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: value)
        var count = UInt32(body.count).littleEndian
        var result = withUnsafeBytes(of: &count) { Data($0) }
        result.append(body)
        return result
    }

    /// 单例查询默认只等很短时间，使拒绝和坏帧回归不拖慢测试。
    private func limits() -> DesktopReceiptLimits {
        var result = DesktopReceiptLimits()
        result.timeout = 0.15
        return result
    }

    /// 读取 accepted 快照后提取关联元数据，并验证只发送初始化与关注/取消关注。
    func testAcceptedCanonicalSnapshotAndReadOnlyActionWhitelist() async throws {
        let server = try ReceiptSocketServer(responses: [thread: try snapshot(state(items: [item()]))])
        defer { server.dispose() }
        let worker = server.start()
        let source = DesktopReplyReceiptSource(root: server.root, limits: limits())
        let receipts = await source.receipts(for: [thread: started.addingTimeInterval(10)], now: started.addingTimeInterval(21))
        await worker.value
        XCTAssertEqual(receipts, [QuestionReplyReceipt(threadID: thread, turnID: turn, clientID: reply,
                                                       receivedAt: started.addingTimeInterval(20), questionItems: ["call_synthetic": [0]])])
        let sent = try server.messages()
        XCTAssertEqual(sent.compactMap { $0["method"] as? String }, ["initialize", "thread-stream-following-changed", "thread-stream-following-changed"])
        XCTAssertEqual((sent[1]["params"] as? [String: Any])?["following"] as? Bool, true)
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["following"] as? Bool, false)
        XCTAssertFalse(server.didTimeout)
    }

    /// pending/failed、错轮次、伪造正文和不可信提交时间都不能解除等待。
    func testUnacceptedMismatchedAndNestedItemsAreRejected() async throws {
        let falseItems = try [
            item(status: "pending"), item(status: "failed"), item(status: "rejected"),
            item(overrides: ["targetTurnId": "00000000-0000-4000-8000-000000000099"]),
            item(overrides: ["clientUserMessageId": "not-a-client-id"]),
            item(overrides: ["restoreMessage": ["createdAt": started.addingTimeInterval(9).timeIntervalSince1970 * 1_000]]),
            item(overrides: ["restoreMessage": ["createdAt": started.addingTimeInterval(22).timeIntervalSince1970 * 1_000]]),
            item(overrides: ["restoreMessage": ["createdAt": true]]),
            item(overrides: ["input": [["type": "text", "text": "quoted " + message()]]])
        ]
        let nested: [String: Any] = ["type": "agentMessage", "text": "synthetic", "metadata": ["items": [try item()]]]
        let server = try ReceiptSocketServer(responses: [thread: try snapshot(state(items: falseItems + [nested]))])
        defer { server.dispose() }
        let worker = server.start()
        let found = await DesktopReplyReceiptSource(root: server.root, limits: limits())
            .receipts(for: [thread: started.addingTimeInterval(10)], now: started.addingTimeInterval(21))
        await worker.value
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(try server.messages().count, 3)
    }

    /// canonical 已进入的新状态优先，旧 turns 镜像和未被 entries 引用的实体不能恢复过时接受项。
    func testCanonicalHistoryExcludesStaleLegacyAndUnreferencedItems() async throws {
        var canonical = try state(items: [item(status: "pending")])
        canonical["turns"] = [["turnId": turn, "status": "inProgress", "items": [try item()]]]
        var history = try XCTUnwrap(canonical["turnHistory"] as? [String: Any])
        var data = try XCTUnwrap(history["history"] as? [String: Any])
        var entities = try XCTUnwrap(data["entitiesByKey"] as? [String: Any])
        entities["unreferenced"] = ["turnId": turn, "status": "inProgress", "items": [try item()]]
        data["entitiesByKey"] = entities; history["history"] = data; canonical["turnHistory"] = history
        let server = try ReceiptSocketServer(responses: [thread: try snapshot(canonical)])
        defer { server.dispose() }
        let worker = server.start()
        let found = await DesktopReplyReceiptSource(root: server.root, limits: limits())
            .receipts(for: [thread: started.addingTimeInterval(10)], now: started.addingTimeInterval(21))
        await worker.value
        XCTAssertTrue(found.isEmpty)
    }

    /// 错来源、错任务、未来协议和停止的桌面轮次均安全回退。
    func testUnknownProtocolWrongSourceAndTerminalTurnFailClosed() async throws {
        let valid = try state(items: [item()])
        let wrongRecipient = try framed(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                                          "targetClientIds": ["unrelated-client"],
                                          "params": ["hostId": "local", "conversationId": thread,
                                                       "change": ["type": "snapshot", "conversationState": valid]]])
        let frames = try [
            snapshot(valid, version: 12), snapshot(valid, version: true),
            snapshot(state(items: [item()], threadID: "00000000-0000-4000-8000-000000000099")),
            snapshot(valid, host: "remote"),
            snapshot(valid, envelopeThread: "00000000-0000-4000-8000-000000000099"),
            snapshot(state(items: [item()], status: "interrupted")),
            snapshot(["id": thread, "hostId": "local", "turns": [], "turnHistory": ["kind": "future"]]),
            wrongRecipient
        ]
        for frame in frames {
            let server = try ReceiptSocketServer(responses: [thread: frame])
            defer { server.dispose() }
            let worker = server.start()
            let found = await DesktopReplyReceiptSource(root: server.root, limits: limits())
                .receipts(for: [thread: started.addingTimeInterval(10)], now: started.addingTimeInterval(21))
            await worker.value
            XCTAssertTrue(found.isEmpty)
            XCTAssertEqual(try server.messages().last?["method"] as? String, "thread-stream-following-changed")
        }
        XCTAssertThrowsError(try DesktopReceiptProtocol.receipts(state: valid, threadID: thread,
                                                                  askedAt: started, now: started.addingTimeInterval(21),
                                                                  limits: limits(), deadline: 0))
    }

    /// 帧可以分段到达，但截断、超大长度和畸形 JSON 不得产生接收凭据。
    func testSplitFramesSucceedAndPartialOversizedInvalidFramesFail() async throws {
        let accepted = try snapshot(state(items: [item()], canonical: false))
        let split = try ReceiptSocketServer(responses: [thread: accepted], splitFrames: true)
        defer { split.dispose() }
        let splitWorker = split.start()
        let source = DesktopReplyReceiptSource(root: split.root, limits: limits())
        let splitReceipts = await source.receipts(for: [thread: started.addingTimeInterval(10)], now: started.addingTimeInterval(21))
        XCTAssertEqual(splitReceipts.count, 1)
        await splitWorker.value
        var rejectionBudget = limits(); rejectionBudget.maximumFrameBytes = 8 * 1_024
        var oversized = UInt32(rejectionBudget.maximumFrameBytes + 1).littleEndian
        let cases = [Data(accepted.prefix(2)), Data(accepted.prefix(accepted.count / 2)),
                     withUnsafeBytes(of: &oversized) { Data($0) }, Data([1, 0, 0, 0, 123])]
        for frame in cases {
            let server = try ReceiptSocketServer(responses: [thread: frame])
            defer { server.dispose() }
            let worker = server.start()
            let found = await DesktopReplyReceiptSource(root: server.root, limits: rejectionBudget)
                .receipts(for: [thread: started.addingTimeInterval(10)], now: started.addingTimeInterval(21))
            await worker.value
            XCTAssertTrue(found.isEmpty)
            XCTAssertFalse(server.didTimeout)
        }
    }

    /// 长任务的完整快照会超过旧 8 MiB 阈值，大段无关字段也不能掩盖其中的精确已接受回答。
    func testLargeSnapshotAboveEightMiBPreservesAcceptedReceipt() async throws {
        var large = try state(items: [item()])
        large["syntheticIgnoredPayload"] = String(repeating: "x", count: 9 * 1_024 * 1_024)
        let frame = try snapshot(large)
        XCTAssertGreaterThan(frame.count, 8 * 1_024 * 1_024)
        let server = try ReceiptSocketServer(responses: [thread: frame])
        defer { server.dispose() }
        let worker = server.start()
        let found = await DesktopReplyReceiptSource(root: server.root)
            .receipts(for: [thread: started.addingTimeInterval(10)], now: started.addingTimeInterval(21))
        await worker.value
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.questionItems, ["call_synthetic": [0]])
        XCTAssertFalse(server.didTimeout)
    }

    /// 无 owner 或未初始化时按总时限返回，不启动服务；累计字节和帧数也有上限。
    func testTimeoutHandshakeFailureAndAggregateBudgets() async throws {
        let harmless = try framed(["type": "broadcast", "method": "synthetic-irrelevant", "padding": String(repeating: "x", count: 100)])
        for mode in 0..<4 {
            var budget = limits()
            if mode == 2 { budget.maximumTotalBytes = 512 }
            if mode == 3 { budget.maximumFrames = 3 }
            let server = try ReceiptSocketServer(responses: mode >= 2 ? [thread: Data(repeatingFrame: harmless, count: 12)] : [:],
                                                 rejectInitialization: mode == 1)
            defer { server.dispose() }
            let worker = server.start()
            let began = ProcessInfo.processInfo.systemUptime
            let found = await DesktopReplyReceiptSource(root: server.root, limits: budget)
                .receipts(for: [thread: started], now: started.addingTimeInterval(21))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.8)
            await worker.value
            XCTAssertTrue(found.isEmpty)
            XCTAssertFalse(server.didTimeout)
        }
    }

    /// 任务取消及时关闭连接并取消关注，不在主线程等待套接字超时。
    @MainActor
    func testCancellationAndMainActorRemainResponsive() async throws {
        let server = try ReceiptSocketServer(responses: [:])
        defer { server.dispose() }
        let worker = server.start()
        var budget = limits(); budget.timeout = 0.8
        let source = DesktopReplyReceiptSource(root: server.root, limits: budget)
        let thread = thread, now = started.addingTimeInterval(21), asked = started
        let pending = Task { await source.receipts(for: [thread: asked], now: now) }
        try await Task.sleep(for: .milliseconds(35))
        let began = ProcessInfo.processInfo.systemUptime
        pending.cancel()
        let cancelledReceipts = await pending.value
        XCTAssertTrue(cancelledReceipts.isEmpty)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.25)
        await worker.value
        let sent = try server.messages()
        XCTAssertEqual((sent.last?["params"] as? [String: Any])?["following"] as? Bool, false)
    }

    /// 超过批量上限时轮转查询，不能让前面长期无答的任务饿死后面的任务。
    func testThreadBudgetRotatesAndRejectsCrossRootSocket() async throws {
        let other = "00000000-0000-4000-8000-000000000004"
        let server = try ReceiptSocketServer(responses: [:], maximumConnections: 2)
        defer { server.dispose() }
        let worker = server.start()
        var budget = limits(); budget.maximumThreads = 1; budget.timeout = 0.06
        let source = DesktopReplyReceiptSource(root: server.root, limits: budget)
        _ = await source.receipts(for: [thread: started, other: started], now: started.addingTimeInterval(21))
        _ = await source.receipts(for: [thread: started, other: started], now: started.addingTimeInterval(21))
        await worker.value
        let followed = try server.messages().compactMap { message -> String? in
            guard let params = message["params"] as? [String: Any], params["following"] as? Bool == true else { return nil }
            return params["conversationId"] as? String
        }
        XCTAssertEqual(Set(followed), [thread, other])
        let alternate = server.root.appendingPathComponent("alternate", isDirectory: true)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alternate.appendingPathComponent("ipc"), withDestinationURL: server.root.appendingPathComponent("ipc"))
        let found = await DesktopReplyReceiptSource(root: alternate).receipts(for: [thread: started], now: started.addingTimeInterval(21))
        XCTAssertTrue(found.isEmpty)
    }

    /// 源快照在正式回复落盘前先显示已回复，计时恢复不覆盖它，正式停止仍优先且源文件不变。
    func testLocalSourceAcceptedProjectionAndAuthoritativeStopWithoutSourceWrites() async throws {
        for status in ["accepted", "pending", "failed"] {
            let server = try ReceiptSocketServer(responses: [thread: try snapshot(state(items: [item(status: status)]))])
            defer { server.dispose() }
            let log = server.root.appendingPathComponent("rollout.jsonl"), databaseURL = server.root.appendingPathComponent("state_5.sqlite")
            let begin = try rollout("task_started", at: 0, extra: ["turn_id": turn])
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["questions": [["title": "合成问题"]]]), as: UTF8.self)
            let ask = try rollout("function_call", at: 10, kind: "response_item", extra: ["name": "request_user_input_async", "call_id": "call_synthetic", "arguments": arguments])
            try (begin + ask).write(to: log)
            try database(at: databaseURL, rollout: log)
            let originalDB = try Data(contentsOf: databaseURL), originalLog = try Data(contentsOf: log)
            let source = LocalCodexSource(root: server.root), worker = server.start()
            let first = try await source.snapshot(now: started.addingTimeInterval(21), recoverTimingFor: [thread])
            await worker.value
            let activity = try XCTUnwrap(first.tasks.first?.activity)
            XCTAssertEqual(activity.phase, status == "accepted" ? .running : .waiting)
            if status == "accepted" { XCTAssertEqual(activity.detail, "已回复，等待继续") }
            XCTAssertEqual(activity.startedAt, started)
            XCTAssertEqual(activity.lastEventAt, started.addingTimeInterval(10))
            XCTAssertEqual(try Data(contentsOf: databaseURL), originalDB)
            XCTAssertEqual(try Data(contentsOf: log), originalLog)
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: rollout("turn_aborted", at: 22, extra: ["turn_id": turn]))
            try handle.close()
            let stoppedLog = try Data(contentsOf: log)
            let stopped = try await source.snapshot(now: started.addingTimeInterval(23), recoverTimingFor: [thread])
            XCTAssertEqual(stopped.tasks.first?.activity.phase, .stopped)
            XCTAssertEqual(try Data(contentsOf: log), stoppedLog)
            XCTAssertEqual(try Data(contentsOf: databaseURL), originalDB)
        }
    }

    /// 创建独立状态库，所有写入只发生在合成测试准备阶段。
    private func database(at url: URL, rollout: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER);
        INSERT INTO threads VALUES('\(thread)','Synthetic','/synthetic','\(rollout.path)',1,2,0);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    /// 构造单条合成任务历史，精确控制先后顺序而无需等待真实执行。
    private func rollout(_ type: String, at seconds: Double, kind: String = "event_msg", extra: [String: Any]) throws -> Data {
        var payload = extra; payload["type"] = type
        return try JSONSerialization.data(withJSONObject: ["type": kind, "timestamp": ISO8601DateFormatter().string(from: started.addingTimeInterval(seconds)), "payload": payload]) + Data([10])
    }
}

/// 合成 IPC 对端；只绑定独立临时目录，记录收到的协议消息以断言动作白名单。
private final class ReceiptSocketServer: @unchecked Sendable {
    let root: URL
    private let listener: Int32
    private let responses: [String: Data]
    private let splitFrames: Bool
    private let rejectInitialization: Bool
    private let maximumConnections: Int
    private let lock = NSLock()
    private var recorded: [Data] = []
    private var timedOut = false
    var didTimeout: Bool { lock.withLock { timedOut } }

    /// 预先建立测试监听端点，让被测源只需连接现存 socket。
    init(responses: [String: Data], splitFrames: Bool = false, rejectInitialization: Bool = false,
         maximumConnections: Int = 1) throws {
        root = URL(fileURLWithPath: "/private/tmp/codex-receipt-" + UUID().uuidString.prefix(8), isDirectory: true)
        self.responses = responses; self.splitFrames = splitFrames
        self.rejectInitialization = rejectInitialization; self.maximumConnections = maximumConnections
        let ipc = root.appendingPathComponent("ipc", isDirectory: true)
        try FileManager.default.createDirectory(at: ipc, withIntermediateDirectories: true)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CocoaError(.fileReadUnknown) }
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(ipc.appendingPathComponent("ipc.sock").path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { path in
            path.initializeMemory(as: UInt8.self, repeating: 0); path.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, Darwin.listen(listener, 1) == 0 else { Darwin.close(listener); throw CocoaError(.fileReadUnknown) }
    }

    /// 在独立工作线程响应协议，不阻塞异步测试或主线程。
    func start() -> Task<Void, Never> { Task.detached { self.serve() } }

    /// 销毁合成套接字及临时目录，不触碰任何真实 Codex 数据。
    func dispose() { Darwin.close(listener); try? FileManager.default.removeItem(at: root) }

    /// 在服务结束后解码捕获的消息，测试只断言类型和关联字段。
    func messages() throws -> [[String: Any]] {
        try lock.withLock { try recorded.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) } }
    }

    /// 有界接收测试客户端，成功取消关注或断开都会结束该连接。
    private func serve() {
        let until = ProcessInfo.processInfo.systemUptime + 3
        for _ in 0..<maximumConnections {
            var client: Int32 = -1
            while ProcessInfo.processInfo.systemUptime < until {
                client = Darwin.accept(listener, nil, nil)
                if client >= 0 { break }
                var fd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                _ = poll(&fd, 1, 10)
            }
            guard client >= 0 else { lock.withLock { timedOut = true }; return }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            exchange(client: client, until: until)
            Darwin.close(client)
        }
    }

    /// 初始化成功后按目标任务返回预置帧，持续读取以确认客户端清理消息。
    private func exchange(client: Int32, until: TimeInterval) {
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 4_096)
        while ProcessInfo.processInfo.systemUptime < until {
            var fd = pollfd(fd: client, events: Int16(POLLIN | POLLHUP), revents: 0)
            guard poll(&fd, 1, 10) > 0 else { continue }
            let count = Darwin.read(client, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; return }
            buffer.append(contentsOf: bytes.prefix(count))
            while buffer.count >= 4 {
                let size = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                guard size <= 65_536 else { return }
                guard buffer.count >= size + 4 else { break }
                let body = Data(buffer.dropFirst(4).prefix(size)); buffer.removeFirst(size + 4)
                lock.withLock { recorded.append(body) }
                guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
                if message["method"] as? String == "initialize", let request = message["requestId"] as? String {
                    let response: [String: Any] = ["type": "response", "requestId": request, "method": "initialize",
                                                   "resultType": rejectInitialization ? "error" : "success",
                                                   "result": ["clientId": "00000000-0000-4000-8000-000000000009"]]
                    if let data = try? JSONSerialization.data(withJSONObject: response) {
                        var length = UInt32(data.count).littleEndian
                        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
                        write(frame, to: client, until: until)
                    }
                } else if message["method"] as? String == "thread-stream-following-changed",
                          let params = message["params"] as? [String: Any], params["following"] as? Bool == true,
                          let thread = params["conversationId"] as? String, let frame = responses[thread] {
                    write(frame, to: client, until: until)
                }
            }
        }
        lock.withLock { timedOut = true }
    }

    /// 有意支持逐字节短写，覆盖长度头和 JSON 正文分别分片的情况。
    private func write(_ data: Data, to client: Int32, until: TimeInterval) {
        var offset = 0
        while offset < data.count, ProcessInfo.processInfo.systemUptime < until {
            let size = splitFrames ? min(3, data.count - offset) : data.count - offset
            let count = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress!.advanced(by: offset), size) }
            if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; return }
            if count == 0 { return }
            offset += count
        }
    }
}

private extension Data {
    /// 拼接有限数量的广播，验证累计预算而不是只有单帧预算。
    init(repeatingFrame frame: Data, count: Int) {
        self.init()
        for _ in 0..<count { append(frame) }
    }
}
