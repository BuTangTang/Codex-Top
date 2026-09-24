import Foundation
import CryptoKit
import Darwin

/// Codex Top 产品账号的配置；不读取或改写 Codex 的认证文件。
public struct MobileAccountConfiguration: Sendable {
    public let serverURL: URL
    public let home: URL
    public let executable: URL?

    /// 仅允许 HTTPS 服务；回环 HTTP 必须由本机开发环境明确开启。
    public init(serverAddress: String, home: URL, executable: URL?, allowLoopback: Bool = false) throws {
        guard var parts = URLComponents(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (allowLoopback && parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw MobileAccountError.invalidServer }
        parts.path = ""
        guard let url = parts.url else { throw MobileAccountError.invalidServer }
        self.serverURL = url
        self.home = home.standardizedFileURL
        self.executable = executable
    }

    /// 为连接组件固定独立目录和服务身份，避免继承其他会话的认证环境。
    var environment: [String: String] {
        var result = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HAPPIER_") && !$0.key.hasPrefix("HAPPY_") }
        let fingerprint = SHA256.hash(data: Data(serverURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        result["HAPPIER_HOME_DIR"] = home.path
        result["HAPPIER_SERVER_URL"] = serverURL.absoluteString
        result["HAPPIER_ACTIVE_SERVER_ID"] = "codextop_" + fingerprint
        result["HAPPIER_NO_BROWSER"] = "1"
        result["HAPPIER_PRODUCT_MODE"] = "codextop"
        return result
    }
}

/// 只承载可显示的账号状态，不接收 token、密码或解密材料。
public struct MobileAccountSession: Decodable, Sendable, Equatable {
    public let accountId: String
    public let loginName: String?
    public let host: String?
    public let machineRegistered: Bool?
    public let daemonRunning: Bool?
}

/// 本机组件错误采用固定中文文案，不能把后端原始错误带入界面。
public enum MobileAccountError: Error, LocalizedError, Equatable, Sendable {
    case invalidServer, componentMissing, invalidResponse, invalidCredentials, sourceConflict
    case notAuthenticated, unavailable, timedOut, connectionFailed, rateLimited, alreadyAuthenticated, invalidInput

    public var errorDescription: String? {
        switch self {
        case .invalidServer: return "请在连接设置中填写有效的 HTTPS 服务地址。"
        case .componentMissing: return "手机连接组件不可用，请使用包含连接组件的 Codex Top 安装包。"
        case .invalidResponse: return "连接组件返回了无法识别的结果，请更新后重试。"
        case .invalidCredentials: return "账号或密码不正确。"
        case .sourceConflict: return "这台电脑的数据已属于另一个账号。请在独立的系统用户中连接，避免共享历史会话。"
        case .notAuthenticated: return "请先登录。"
        case .unavailable: return "暂时无法连接服务，已保存的登录信息会保留。"
        case .timedOut: return "连接超时，请检查网络后重试。"
        case .connectionFailed: return "电脑尚未连接，请重试。"
        case .rateLimited: return "尝试次数过多，请稍后再试。"
        case .alreadyAuthenticated: return "本机已有登录，请先退出当前账号。"
        case .invalidInput: return "请输入有效的账号和密码。"
        }
    }
}

/// 原生界面只调用产品 CLI 的既有账号 owner，不另存一套认证身份。
public struct MobileAccountClient: Sendable {
    public let configuration: MobileAccountConfiguration
    private let timeout: TimeInterval

    /// 整次本机调用有界运行；超时或取消会回收该次拥有的子进程。
    public init(configuration: MobileAccountConfiguration, timeout: TimeInterval = 60) {
        self.configuration = configuration
        self.timeout = timeout
    }

    /// 查询服务器已验证的身份；离线不得把未知状态显示为已退出。
    public func status() async throws -> MobileAccountSession {
        let response = try await run(arguments: ["auth", "status", "--json"], kind: "auth_status")
        guard let session = response.data, response.authenticated == true, !session.accountId.isEmpty else {
            throw MobileAccountError.invalidResponse
        }
        return session
    }

    /// 密码只通过标准输入传递，不进入进程参数、偏好或日志。
    public func login(name: String, password: String) async throws {
        // 与统一 CLI 的输入协议一致，避免超长粘贴阻塞标准输入管道。
        guard (1...128).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count), (1...1024).contains(password.utf16.count) else { throw MobileAccountError.invalidInput }
        let input = try JSONEncoder().encode(LoginInput(loginName: name, password: password))
        let response = try await run(arguments: ["auth", "password-login", "--json"], kind: "auth_password_login", input: input)
        guard response.authenticated == true, response.data?.accountId.isEmpty == false else { throw MobileAccountError.invalidResponse }
    }

    /// 退出当前连接组件的账号；不要求服务器撤销其他设备的登录。
    public func logout() async throws {
        let result = try await run(arguments: ["auth", "logout", "--yes", "--json"], kind: "auth_logout")
        guard result.loggedOut == true else { throw MobileAccountError.invalidResponse }
    }

    /// 启动本产品的电脑连接，保留 daemon 原 owner 的冲突判断，不强行接管其他进程。
    public func connect() async throws {
        let data = try await MobileAccountProcess(configuration: configuration, arguments: ["daemon", "start", "--json"], input: Data(), timeout: timeout).execute()
        guard let result = try? JSONDecoder().decode(ConnectionResponse.self, from: data) else { throw MobileAccountError.invalidResponse }
        guard result.ok, ["started", "starting", "already_running"].contains(result.status ?? "") else { throw MobileAccountError.connectionFailed }
    }

    /// 解码唯一 JSON 回执，拒绝版本或操作不匹配的响应。
    private func run(arguments: [String], kind: String, input: Data = Data()) async throws -> BridgeResponse {
        let data = try await MobileAccountProcess(configuration: configuration, arguments: arguments, input: input, timeout: timeout).execute()
        guard let result = try? JSONDecoder().decode(BridgeResponse.self, from: data), result.v == 1, result.kind == kind else {
            throw MobileAccountError.invalidResponse
        }
        guard result.ok else {
            switch result.error?.code {
            case "not_authenticated": throw MobileAccountError.notAuthenticated
            case "invalid_credentials", "password_auth_failed", "authentication_failed": throw MobileAccountError.invalidCredentials
            case "source_account_conflict": throw MobileAccountError.sourceConflict
            case "invalid_server_url", "insecure_server_url", "insecure_transport": throw MobileAccountError.invalidServer
            case "rate_limited": throw MobileAccountError.rateLimited
            case "already_authenticated": throw MobileAccountError.alreadyAuthenticated
            case "invalid_input", "invalid_arguments", "stdin_required": throw MobileAccountError.invalidInput
            default: throw MobileAccountError.unavailable
            }
        }
        return result
    }

    private struct LoginInput: Encodable { let loginName: String; let password: String }
    private struct ConnectionResponse: Decodable { let ok: Bool; let status: String? }

    private struct BridgeResponse: Decodable {
        let v: Int
        let ok: Bool
        let kind: String
        let data: MobileAccountSession?
        let authenticated: Bool?
        let loggedOut: Bool?
        let error: Failure?
        private enum CodingKeys: String, CodingKey { case v, ok, kind, data, error }
        private struct Body: Decodable {
            let accountId: String?
            let loginName: String?
            let host: String?
            let machineRegistered: Bool?
            let daemonRunning: Bool?
            let authenticated: Bool?
            let loggedOut: Bool?
        }
        struct Failure: Decodable { let code: String }

        /// 不同命令的数据字段可选，成功登录状态仍须由 status() 单独校验。
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            v = try values.decode(Int.self, forKey: .v)
            ok = try values.decode(Bool.self, forKey: .ok)
            kind = try values.decode(String.self, forKey: .kind)
            error = try values.decodeIfPresent(Failure.self, forKey: .error)
            let body = try values.decodeIfPresent(Body.self, forKey: .data)
            authenticated = body?.authenticated
            loggedOut = body?.loggedOut
            data = body?.accountId.map { MobileAccountSession(accountId: $0, loginName: body?.loginName, host: body?.host, machineRegistered: body?.machineRegistered, daemonRunning: body?.daemonRunning) }
        }
    }
}

/// 有取消和超时的私有进程边界，只停止本次启动的命令，不扫描系统进程。
private final class MobileAccountProcess: @unchecked Sendable {
    private let configuration: MobileAccountConfiguration
    private let arguments: [String]
    private let input: Data
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false

    /// 固定本次请求的服务和输入，运行期间不追随界面上更改的地址。
    init(configuration: MobileAccountConfiguration, arguments: [String], input: Data, timeout: TimeInterval) {
        self.configuration = configuration; self.arguments = arguments; self.input = input; self.timeout = timeout
    }

    /// 将阻塞的本机管道放在后台，保持原生监控和设置界面可交互。
    func execute() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try self.run() })
                }
            }
        } onCancel: { self.lock.withLock { self.cancelled = true } }
    }

    /// 在启动和读取期间检查取消，确保退出界面的旧调用不会继续返回成功。
    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    /// 读取有界 JSON 输出；丢弃 stderr 防止认证或底层路径泄露到界面。
    private func run() throws -> Data {
        try checkCancellation()
        guard let executable = configuration.executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MobileAccountError.componentMissing
        }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = configuration.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw MobileAccountError.componentMissing }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        let writer = stdin.fileHandleForWriting, reader = stdout.fileHandleForReading
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        // 命令结束前总是回收，避免已取消的登录请求成为无人管理的后台进程。
        defer {
            try? writer.close()
            if process.isRunning { process.terminate() }
            let grace = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? reader.close()
        }
        do { try writer.write(contentsOf: input); try writer.close() } catch { throw MobileAccountError.unavailable }
        let startedAt = ProcessInfo.processInfo.systemUptime
        var output = Data(), chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - startedAt < timeout else { throw MobileAccountError.timedOut }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; throw MobileAccountError.unavailable }
            if ready == 0 { continue }
            let count = Darwin.read(reader.fileDescriptor, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue }; throw MobileAccountError.unavailable }
            if count == 0 { return output }
            output.append(contentsOf: chunk.prefix(count))
            // 沿用本机只读 CLI 边界的 1 MiB 上限，超出说明回执协议异常。
            guard output.count <= 1_048_576 else { throw MobileAccountError.invalidResponse }
        }
    }
}
