import Foundation
import CoreFoundation
import Darwin

/// 从现存桌面进程短时订阅读取已接受的回答；不启动、恢复或取得任何任务的执行权。
public actor DesktopReplyReceiptSource {
    private let root: URL
    private let limits: DesktopReceiptLimits
    private var nextThread = 0

    /// 固定所选数据根目录；不同数据来源不会共用连接或回答缓存。
    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        limits = DesktopReceiptLimits()
    }

    /// 允许合成套接字测试缩小预算；正式调用始终使用固定的有界默认值。
    init(root: URL, limits: DesktopReceiptLimits) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits
    }

    /// 在独立工作任务中执行有界套接字读取，避免阻塞主线程；失败仅返回空辅助证据。
    public func receipts(for threads: [String: Date], now: Date) async -> [QuestionReplyReceipt] {
        guard now.timeIntervalSince1970.isFinite, !threads.isEmpty, !Task.isCancelled else { return [] }
        let eligible = threads.filter {
            DesktopReceiptProtocol.isUUID($0.key) && $0.value.timeIntervalSince1970.isFinite && $0.value <= now
        }
        let keys = eligible.keys.sorted()
        guard !keys.isEmpty, limits.maximumThreads > 0 else { nextThread = 0; return [] }
        let first = nextThread % keys.count
        let count = min(keys.count, limits.maximumThreads)
        let selectedKeys = (0..<count).map { keys[(first + $0) % keys.count] }
        nextThread = (first + count) % keys.count
        let selected = Dictionary(uniqueKeysWithValues: selectedKeys.map { ($0, eligible[$0]!) })
        guard !selected.isEmpty else { return [] }
        let root = root, limits = limits
        let worker = Task.detached(priority: .utility) {
            do { return try DesktopReceiptConnection(root: root, limits: limits).read(threads: selected, now: now) }
            catch { return [QuestionReplyReceipt]() }
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
}

/// 限制辅助读取的时长、内存和任务数量，桌面历史过大时安全回退到正式任务记录。
struct DesktopReceiptLimits: Sendable {
    var timeout: TimeInterval = 1.5
    var maximumThreads = 16
    var maximumFrameBytes = 64 * 1_024 * 1_024
    var maximumTotalBytes = 96 * 1_024 * 1_024
    var maximumFrames = 128
    var maximumTurns = 512
    var maximumItems = 16_384
    var maximumReceipts = 128
}

private enum DesktopReceiptError: Error { case unavailable, invalid, timedOut, cancelled }

/// 仅保留同一次查询的临时传输状态，原始快照在读取结束后释放。
private final class DesktopReceiptConnection {
    private let root: URL
    private let limits: DesktopReceiptLimits
    private var descriptor: Int32 = -1
    private var bytesRead = 0
    private var framesRead = 0
    private var clientID: String?
    private var followed: [String] = []
    private var deadline: TimeInterval = 0

    /// 为一次有界查询建立临时状态，不在构造时连接或写入磁盘。
    init(root: URL, limits: DesktopReceiptLimits) { self.root = root; self.limits = limits }

    /// 仅使用初始化和关注广播；收到目标快照后立即取消关注并关闭连接。
    func read(threads: [String: Date], now: Date) throws -> [QuestionReplyReceipt] {
        guard limits.timeout.isFinite, limits.timeout > 0, limits.maximumFrameBytes > 0,
              limits.maximumTotalBytes >= 4, limits.maximumFrames > 0 else { return [] }
        deadline = ProcessInfo.processInfo.systemUptime + limits.timeout
        // 留出极短的清理预算；即使取消或协议错误，也尽力解除临时关注。
        let readDeadline = deadline - min(0.02, limits.timeout / 10)
        defer { close() }
        try connect(until: readDeadline)
        let requestID = UUID().uuidString
        try send(["type": "request", "requestId": requestID, "sourceClientId": "initializing-client",
                  "version": 0, "method": "initialize", "params": ["clientType": "codex-top-reply-observer"]], until: readDeadline)
        while clientID == nil {
            let message = try receive(until: readDeadline)
            guard message["type"] as? String == "response", message["requestId"] as? String == requestID else { continue }
            guard message["method"] as? String == "initialize", message["resultType"] as? String == "success",
                  let result = message["result"] as? [String: Any], let id = result["clientId"] as? String,
                  DesktopReceiptProtocol.isUUID(id) else { throw DesktopReceiptError.invalid }
            clientID = id
        }
        for thread in threads.keys.sorted() {
            try follow(thread, enabled: true, until: readDeadline)
            followed.append(thread)
        }
        var remaining = Set(threads.keys), receipts: [QuestionReplyReceipt] = []
        while !remaining.isEmpty {
            let message: [String: Any]
            do { message = try receive(until: readDeadline) }
            catch DesktopReceiptError.timedOut { break }
            guard message["type"] as? String == "broadcast",
                  message["method"] as? String == "thread-stream-state-changed",
                  let params = message["params"] as? [String: Any], params["hostId"] as? String == "local",
                  let thread = params["conversationId"] as? String, remaining.contains(thread) else { continue }
            guard DesktopReceiptProtocol.integer(message["version"]) == 11 else { throw DesktopReceiptError.invalid }
            if let value = message["targetClientIds"] {
                guard let recipients = value as? [String] else { throw DesktopReceiptError.invalid }
                if !recipients.contains(clientID!) { continue }
            }
            guard let change = params["change"] as? [String: Any] else { throw DesktopReceiptError.invalid }
            // 不重建增量补丁，以免版本缺口或部分历史成为错误的已回答证据。
            guard change["type"] as? String == "snapshot" else { continue }
            guard let state = change["conversationState"] as? [String: Any] else { throw DesktopReceiptError.invalid }
            receipts += try DesktopReceiptProtocol.receipts(state: state, threadID: thread,
                                                             askedAt: threads[thread]!, now: now, limits: limits,
                                                             deadline: readDeadline)
            guard receipts.count <= limits.maximumReceipts else { throw DesktopReceiptError.invalid }
            remaining.remove(thread)
        }
        guard !Task.isCancelled else { throw DesktopReceiptError.cancelled }
        return receipts.sorted {
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
            if $0.threadID != $1.threadID { return $0.threadID < $1.threadID }
            return $0.clientID < $1.clientID
        }
    }

    /// 只连接同根目录、同用户拥有的现存 socket，禁止符号链接跨根和自动建立服务。
    private func connect(until deadline: TimeInterval) throws {
        let directory = root.appendingPathComponent("ipc", isDirectory: true)
        let socketURL = directory.appendingPathComponent("ipc.sock")
        guard directory.resolvingSymlinksInPath() == directory, socketURL.resolvingSymlinksInPath() == socketURL else { throw DesktopReceiptError.unavailable }
        var folder = stat(), endpoint = stat()
        guard lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
              folder.st_uid == getuid(), folder.st_mode & (S_IWGRP | S_IWOTH) == 0,
              lstat(socketURL.path, &endpoint) == 0, endpoint.st_mode & S_IFMT == S_IFSOCK,
              endpoint.st_uid == getuid() else { throw DesktopReceiptError.unavailable }
        let bytes = Array(socketURL.path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw DesktopReceiptError.unavailable }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { path in
            path.initializeMemory(as: UInt8.self, repeating: 0)
            path.copyBytes(from: bytes)
        }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw DesktopReceiptError.unavailable }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else { throw DesktopReceiptError.unavailable }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw DesktopReceiptError.unavailable }
            try wait(for: Int16(POLLOUT), until: deadline)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw DesktopReceiptError.unavailable }
        }
        var user: uid_t = 0, group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else { throw DesktopReceiptError.unavailable }
    }

    /// 对目标任务发送只读关注状态，不使用任何执行、恢复、输入或所有权请求。
    private func follow(_ thread: String, enabled: Bool, until deadline: TimeInterval, cleaningUp: Bool = false) throws {
        guard let clientID else { throw DesktopReceiptError.invalid }
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": clientID,
                  "version": 1, "params": ["hostId": "local", "conversationId": thread, "following": enabled]],
                 until: deadline, cleaningUp: cleaningUp)
    }

    /// 编码小端长度帧并处理短写；使用非阻塞描述符确保关闭服务不会挂住快照。
    private func send(_ message: [String: Any], until deadline: TimeInterval, cleaningUp: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= 16_384 else { throw DesktopReceiptError.invalid }
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        var offset = 0
        while offset < frame.count {
            try wait(for: Int16(POLLOUT), until: deadline, cleaningUp: cleaningUp)
            let count = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw DesktopReceiptError.unavailable }
            guard count > 0 else { throw DesktopReceiptError.unavailable }
            offset += count
        }
    }

    /// 先校验长度再分配消息空间，累计帧数和字节预算覆盖无关广播与半帧攻击。
    private func receive(until deadline: TimeInterval) throws -> [String: Any] {
        guard framesRead < limits.maximumFrames else { throw DesktopReceiptError.invalid }
        let header = try readExactly(4, until: deadline)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) }
        guard length > 0, length <= limits.maximumFrameBytes,
              Int(length) <= limits.maximumTotalBytes - bytesRead else { throw DesktopReceiptError.invalid }
        let body = try readExactly(Int(length), until: deadline)
        framesRead += 1
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw DesktopReceiptError.timedOut }
        guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw DesktopReceiptError.invalid }
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw DesktopReceiptError.timedOut }
        return message
    }

    /// 使用短间隔 poll 读取指定字节数，取消、超时和连接中断均立刻停止本次辅助查询。
    private func readExactly(_ count: Int, until deadline: TimeInterval) throws -> Data {
        guard count <= limits.maximumTotalBytes - bytesRead else { throw DesktopReceiptError.invalid }
        var data = Data(count: count), offset = 0
        while offset < count {
            try wait(for: Int16(POLLIN), until: deadline)
            let read = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            if read < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw DesktopReceiptError.unavailable }
            guard read > 0 else { throw DesktopReceiptError.unavailable }
            offset += read; bytesRead += read
        }
        return data
    }

    /// 等待描述符就绪；清理阶段忽略任务取消但仍受同一个总时限限制。
    private func wait(for events: Int16, until deadline: TimeInterval, cleaningUp: Bool = false) throws {
        while true {
            if !cleaningUp && Task.isCancelled { throw DesktopReceiptError.cancelled }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DesktopReceiptError.timedOut }
            var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(10, max(1, remaining * 1_000))))
            if result < 0 { if errno == EINTR { continue }; throw DesktopReceiptError.unavailable }
            if result == 0 { continue }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw DesktopReceiptError.unavailable }
        }
    }

    /// 尽力发送取消关注后关闭，断连本身也让桌面移除临时客户端及所有关注。
    private func close() {
        guard descriptor >= 0 else { return }
        for thread in followed { try? follow(thread, enabled: false, until: deadline, cleaningUp: true) }
        Darwin.close(descriptor); descriptor = -1
    }
}

/// 只解释已知快照容器和直接消息项，不递归搜索工具正文中的类似字段。
enum DesktopReceiptProtocol {
    /// 校验完整快照的来源和轮次后，将已接受回复转换为不含正文的关联元数据。
    static func receipts(state: [String: Any], threadID: String, askedAt: Date, now: Date,
                         limits: DesktopReceiptLimits, deadline: TimeInterval = .infinity) throws -> [QuestionReplyReceipt] {
        guard state["id"] as? String == threadID, state["hostId"] as? String == "local" else { throw DesktopReceiptError.invalid }
        var turns: [[String: Any]] = []
        if let history = state["turnHistory"] as? [String: Any] {
            switch history["kind"] as? String {
            case "canonical":
                // canonical 是当前写入和接受状态的权威来源；不合并可能过时的 turns 镜像。
                guard let data = history["history"] as? [String: Any],
                      let islands = data["islands"] as? [[String: Any]],
                      let entities = data["entitiesByKey"] as? [String: Any],
                      islands.count <= limits.maximumTurns, entities.count <= limits.maximumTurns else { throw DesktopReceiptError.invalid }
                for island in islands {
                    guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw DesktopReceiptError.timedOut }
                    guard let entries = island["entries"] as? [[String: Any]], entries.count <= limits.maximumTurns else { throw DesktopReceiptError.invalid }
                    for entry in entries {
                        guard let key = entry["value"] as? String, let turn = entities[key] as? [String: Any] else { throw DesktopReceiptError.invalid }
                        turns.append(turn)
                        guard turns.count <= limits.maximumTurns else { throw DesktopReceiptError.invalid }
                    }
                }
            case "legacy":
                guard let legacy = state["turns"] as? [[String: Any]] else { throw DesktopReceiptError.invalid }
                turns = legacy
            default: throw DesktopReceiptError.invalid
            }
        } else if state["turnHistory"] == nil, let legacy = state["turns"] as? [[String: Any]] {
            turns = legacy
        } else {
            throw DesktopReceiptError.invalid
        }
        guard turns.count <= limits.maximumTurns else { throw DesktopReceiptError.invalid }
        var result: [QuestionReplyReceipt] = [], seen: Set<String> = [], itemCount = 0
        for turn in turns {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw DesktopReceiptError.timedOut }
            guard turn["status"] as? String == "inProgress", let turnID = turn["turnId"] as? String,
                  isUUID(turnID), let items = turn["items"] as? [[String: Any]] else { continue }
            itemCount += items.count
            guard itemCount <= limits.maximumItems else { throw DesktopReceiptError.invalid }
            for item in items {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw DesktopReceiptError.timedOut }
                guard item["type"] as? String == "steeringUserMessage", item["status"] as? String == "accepted",
                      item["targetTurnId"] as? String == turnID,
                      let clientID = item["clientUserMessageId"] as? String, isUUID(clientID),
                      let restore = item["restoreMessage"] as? [String: Any],
                      let milliseconds = number(restore["createdAt"]), milliseconds >= 0,
                      let input = item["input"] as? [[String: Any]], input.count == 1,
                      input[0]["type"] as? String == "text", let text = input[0]["text"] as? String else { continue }
                let receivedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
                guard receivedAt >= askedAt, receivedAt <= now,
                      let receipt = QuestionReplyReceipt.parse(text: text, threadID: threadID, turnID: turnID,
                                                                clientID: clientID, receivedAt: receivedAt) else { continue }
                let key = turnID + ":" + clientID
                guard seen.insert(key).inserted else { continue }
                result.append(receipt)
                guard result.count <= limits.maximumReceipts else { throw DesktopReceiptError.invalid }
            }
        }
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw DesktopReceiptError.timedOut }
        return result
    }

    /// 严格识别 UUID，不允许附加标记或超长字段进入关联缓存。
    static func isUUID(_ text: String) -> Bool { text.utf8.count == 36 && UUID(uuidString: text) != nil }

    /// 拒绝布尔值和非有限数字，避免 JSON 的 NSNumber 桥接误认时间或版本。
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    /// 版本字段必须是可精确表示的整数，不能宽松转换小数或布尔值。
    static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded() == number, number >= Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }
}
