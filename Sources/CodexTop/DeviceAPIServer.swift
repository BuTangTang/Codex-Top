import Foundation
import Network
import SystemConfiguration
import CodexTopCore

/// REQ-005 设备读取接口：在电脑上等设备来问，四个地址只认读取、打开任务只认提交，局域网来的要带口令；
/// 打开局域网时顺便广播。内容由调用方从面板结果现拼（不读磁盘），这里只管收发。
/// 请求很少、很小，全部放在主线程：网络收发本身是异步的，不会卡面板。
@MainActor final class DeviceAPIServer {
    enum Route: String, CaseIterable {
        case status = "/api/v1/status", tasks = "/api/v1/tasks", usage = "/api/v1/usage", theme = "/api/v1/theme"
    }
    /// 打开任务的回话：状态码和内容。
    typealias OpenReply = @MainActor @Sendable (Int, Data) -> Void
    struct Config: Equatable {
        var lan: Bool
        var token: String?
        var port: UInt16 = DeviceAPI.port
        var serviceName: String
    }

    /// 给设置窗口看的一行状态：nil 表示正常。
    private(set) var problem: String?
    var onStateChange: (() -> Void)?
    /// 测试用：把本机来的请求当成局域网来的，好在回环上测口令（测试时不打开局域网、不广播）。
    var treatsLoopbackAsLAN = false
    var now: () -> Date = { Date() }

    static let maxConnections = 8
    static let maxHeaderBytes = 8 * 1024
    static let requestTimeout: TimeInterval = 5
    static let failureLimit = 5
    static let lockout: TimeInterval = 60

    private let content: (Route) -> Data
    private let open: (String, @escaping OpenReply) -> Void
    private var listener: NWListener?
    private var config: Config?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var failures: [String: (count: Int, blockedUntil: Date?)] = [:]
    private(set) var boundPort: UInt16?

    init(content: @escaping (Route) -> Data, open: @escaping (String, @escaping OpenReply) -> Void) {
        self.content = content; self.open = open
    }

    /// 按设置开服务；设置没变就什么也不做，变了就按新范围重开（换口令只换判断，不用重开）。
    func apply(_ newConfig: Config) {
        let restart = config.map { $0.lan != newConfig.lan || $0.port != newConfig.port || $0.serviceName != newConfig.serviceName } ?? true
        config = newConfig
        if restart || listener == nil { start() }
    }

    func stop() {
        listener?.cancel(); listener = nil; boundPort = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
    }

    private func start() {
        stop()
        guard let config, let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 局域网开关关着：只在本机回环地址上听，局域网设备连不上。
        if !config.lan { parameters.requiredInterfaceType = .loopback }
        do {
            let listener = try NWListener(using: parameters, on: port)
            if config.lan {
                listener.service = NWListener.Service(name: config.serviceName, type: DeviceAPI.serviceType, domain: nil,
                                                      txtRecord: NWTXTRecord(["v": "\(DeviceAPI.schemaVersion)", "auth": "token"]))
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let listener else { return }
                    self?.listenerChanged(state, listener: listener)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            report("接口没能打开：\(error.localizedDescription)")
        }
    }

    private func listenerChanged(_ state: NWListener.State, listener: NWListener) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            boundPort = listener.port?.rawValue
            report(nil)
        case .failed(let error):
            if case .posix(let code) = error, code == .EADDRINUSE {
                report("端口 \(config?.port ?? DeviceAPI.port) 被占用")
            } else {
                report("接口出错：\(error.localizedDescription)")
            }
            listener.cancel()
            self.listener = nil; boundPort = nil
        case .waiting(let error):
            report("接口等待中：\(error.localizedDescription)")
        default: break
        }
    }

    private func report(_ problem: String?) {
        guard self.problem != problem else { return }
        self.problem = problem
        onStateChange?()
    }

    // MARK: 连接

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled: self?.connections[id] = nil
                case .failed: connection?.cancel()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        // 5 秒内没收完就断开；回完之后再取消是空操作。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak connection] in connection?.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    // 请求头分几次到齐时，整段长度也不能超过 8KB。
                    if end.lowerBound - buffer.startIndex > Self.maxHeaderBytes { self.reply(connection, 431, error: "request_too_large"); return }
                    self.handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), connection: connection)
                } else if buffer.count > Self.maxHeaderBytes {
                    self.reply(connection, 431, error: "request_too_large")
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ head: String, connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { reply(connection, 400, error: "bad_request"); return }
        let method = String(request[0])
        let path = String(request[1].split(separator: "?", maxSplits: 1).first ?? "")
        let authorization = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }

        let host = Self.host(of: connection)
        let local = Self.isLoopback(connection) && !treatsLoopbackAsLAN
        if !local {
            // 开关关着时只在回环上听，这里再挡一次局域网来的。
            guard config?.lan == true || treatsLoopbackAsLAN else { reply(connection, 401, error: "unauthorized"); return }
            let now = now()
            if let until = failures[host]?.blockedUntil, until > now { reply(connection, 401, error: "unauthorized"); return }
            guard DeviceAPI.tokenMatches(authorization: authorization, token: config?.token) else {
                // 同一来源连续错 5 次，1 分钟内一律拒绝。
                var record = failures[host] ?? (0, nil)
                record.count += 1
                if record.count >= Self.failureLimit { record = (0, now.addingTimeInterval(Self.lockout)) }
                failures[host] = record
                reply(connection, 401, error: "unauthorized")
                return
            }
            failures[host] = nil
            // 设置“设备”页显示最近一次局域网读取（地址去掉网卡后缀）。
            DeviceAccessMonitor.shared.lastRead = .init(host: String(host.split(separator: "%").first ?? Substring(host)), at: now)
        }
        // 局域网来的先过口令，再看地址和方法：没口令时连地址存不存在都不告诉。
        if let code = Self.openCode(path) {
            guard method == "POST" else { reply(connection, 405, error: "method_not_allowed", allow: "POST"); return }
            open(code) { [weak self] status, body in self?.reply(connection, status, body: body) }
            return
        }
        guard let route = Route(rawValue: path) else { reply(connection, 404, error: "not_found"); return }
        guard method == "GET" else { reply(connection, 405, error: "method_not_allowed", allow: "GET"); return }
        reply(connection, 200, body: content(route))
    }

    /// `/api/v1/tasks/<短编号>/open` 里的短编号（只认十六进制）。
    static func openCode(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0].isEmpty, parts[1] == "api", parts[2] == "v1", parts[3] == "tasks", parts[5] == "open",
              (1...32).contains(parts[4].count), parts[4].allSatisfy(\.isHexDigit) else { return nil }
        return String(parts[4]).lowercased()
    }

    private func reply(_ connection: NWConnection, _ code: Int, body: Data? = nil, error: String? = nil, allow: String? = nil) {
        let body = body ?? Data("{\"error\":\"\(error ?? "error")\"}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                      431: "Request Header Fields Too Large", 502: "Bad Gateway", 503: "Service Unavailable"][code] ?? "Error"
        var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n"
        if let allow { head += "Allow: \(allow)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: 地址

    private static func host(of connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "unknown"
    }

    private static func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    /// 系统设置里的电脑名（比如“butang 的 MacBook Pro”），用作广播名和总览里的电脑名。
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    /// 本机在局域网里的 IPv4 地址（有线或 Wi-Fi），给设置里显示“设备可以访问哪里”。
    static func lanAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(name: String, address: String)] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            candidates.append((name, String(cString: host)))
        }
        return candidates.sorted { $0.name < $1.name }.first?.address
    }
}

extension TaskStore {
    /// 从面板正在用的结果拼接口内容：分段和面板一样（需要你处理 → 刚完成 → 进行中），不读磁盘、不触发刷新。
    func deviceAPIData(_ route: DeviceAPIServer.Route, computer: String, now: Date = Date()) -> Data {
        switch route {
        case .status:
            let summary = statusSummary
            let state = DeviceAPI.OverallState(paused: paused, loading: loading,
                                               sourceUnavailable: sourceWarning != nil && tasks.isEmpty, summary: summary.phase)
            return DeviceAPI.encode(DeviceAPI.status(state: state, summary: summary, freshDone: freshTasks.count,
                                                     watching: active.count, finished: finished.count, computer: computer, now: now))
        case .tasks:
            let graph = self.graph
            let inputs = deviceListedTasks().map { task, section in
                DeviceAPI.TaskInput(id: task.id, origin: task.origin, title: task.title, activity: graph.activity(for: task),
                                    childCount: graph.children[task.id]?.count ?? 0, section: section,
                                    freshFinishedAt: section == .fresh ? freshFinished[task.id] : nil)
            }
            return DeviceAPI.encode(DeviceAPI.tasks(inputs, finishedCount: finished.count,
                                                    titles: preferences.resolvedDeviceShareTitles, now: now))
        case .theme:
            return DeviceAPI.encode(DeviceAPI.theme(choice: themeChoice, effectiveIsDark: theme == .dark, now: now))
        case .usage:
            return DeviceAPI.encode(DeviceAPI.usage(quota: quota, codex: codexUsage, claude: claudeUsage, now: now))
        }
    }

    /// 接口列出的任务和分段：需要你处理 → 刚完成 → 进行中，和面板一样；打开任务也只在这里面找。
    func deviceListedTasks() -> [(task: CodexTask, section: DeviceAPI.Section)] {
        let graph = self.graph
        let fresh = freshTasks, freshIDs = Set(fresh.map(\.id))
        let active = self.active.filter { !freshIDs.contains($0.id) }
        let attention = active.filter { [.waiting, .failed].contains(graph.activity(for: $0).phase) }
        let attentionIDs = Set(attention.map(\.id))
        return attention.map { ($0, .attention) } + fresh.map { ($0, .fresh) }
            + active.filter { !attentionIDs.contains($0.id) }.map { ($0, .active) }
    }

    /// 打开任务（设计 v0.3）：按短编号找，和面板点一行一样打开，按结果回复。
    func deviceOpenTask(code: String, reply: @escaping DeviceAPIServer.OpenReply) {
        guard let task = deviceListedTasks().first(where: { DeviceAPI.taskCode($0.task.id) == code })?.task else {
            reply(404, Data("{\"error\":\"not_found\"}".utf8)); return
        }
        openTask(task) { opened, message in
            reply(opened ? 200 : 502, DeviceAPI.encode(DeviceAPI.OpenResult(opened: opened, message: opened ? nil : message)))
        }
    }
}
