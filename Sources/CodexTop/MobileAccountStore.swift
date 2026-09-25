import AppKit
import Combine
import CodexTopCore

/// 原生账号状态只保存展示信息，认证材料完全由产品连接组件管理。
@MainActor final class MobileAccountStore: ObservableObject {
    @Published var serverAddress: String
    @Published private(set) var session: MobileAccountSession?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var loginNeedsVerification = false
    private let defaults: UserDefaults
    private var operation: Task<Void, Never>?

    /// 优先恢复用户保存的服务地址；首次安装使用发布包指定地址，登录仍由组件核实。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "codexTopConnectionServer")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 发布地址只提供表单初值，不覆盖既有配置，也不代表账号已登录。
        serverAddress = saved.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "CodexTopConnectionServer") as? String ?? "") : saved
    }

    var hasLogin: Bool { session != nil || loginNeedsVerification }
    var codexIsOpen: Bool { NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains { !$0.isTerminated } }

    /// 服务配置按单次调用固定，产品 HOME 不暴露为可切换的账号绕过入口。
    private func client() throws -> MobileAccountClient {
        let manager = FileManager.default
        let home = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexTop/connection", isDirectory: true)
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("connection/codex-top-bridge")
        let override = ProcessInfo.processInfo.environment["CODEX_TOP_BRIDGE_EXECUTABLE"]
        let executable = override.map { URL(fileURLWithPath: $0) } ?? bundled
        return MobileAccountClient(configuration: try MobileAccountConfiguration(
            serverAddress: serverAddress, home: home, executable: executable,
            allowLoopback: ProcessInfo.processInfo.environment["CODEX_TOP_ALLOW_LOOPBACK"] == "1"
        ))
    }

    /// 只在未登录时保存服务地址，防止编辑地址把当前账号指向另一个服务。
    func saveConnection() {
        guard !busy, !hasLogin else { return }
        do {
            let client = try client()
            serverAddress = client.configuration.serverURL.absoluteString
            defaults.set(serverAddress, forKey: "codexTopConnectionServer")
            notice = nil
            refresh()
        } catch { notice = error.localizedDescription }
    }

    /// 恢复账号后由组件原 owner 校验连接及版本；登录验证失败不影响本机任务监控。
    func refresh(connectIfNeeded: Bool = false) {
        guard !busy, !serverAddress.isEmpty else { return }
        begin(offlineMeansStoredLogin: true) { client in
            let status = try await client.status()
            self.session = status
            self.loginNeedsVerification = false
            // 已启动只证明进程存活；仍调用 canonical start，让其判断旧版本替换或 owner 冲突。
            if connectIfNeeded {
                try await client.connect()
                self.session = try await client.status()
            }
        }
    }

    /// 显式登录意味着连接当前系统用户的会话，密码不写入任何偏好。
    func login(name: String, password: String) {
        guard !busy, !hasLogin, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        begin(offlineMeansStoredLogin: true) { client in
            // 登录可能先落盘再遭遇断线；先保留已校验的非秘密地址，重启仍能核实或退出。
            self.serverAddress = client.configuration.serverURL.absoluteString
            self.defaults.set(self.serverAddress, forKey: "codexTopConnectionServer")
            try await client.login(name: name, password: password)
            self.loginNeedsVerification = true
            // 先重新校验实际持久身份；连接失败仍保留已登录信息并提供重试。
            self.session = try await client.status()
            self.loginNeedsVerification = false
            try await client.connect()
            self.session = try await client.status()
        }
    }

    /// 退出由组件先停止旧账号连接，成功后才清除原生展示，不声称其他端被退出。
    func logout() {
        guard !busy else { return }
        begin { client in
            try await client.logout()
            self.session = nil
            self.loginNeedsVerification = false
        }
    }

    /// 串行执行账号操作，避免登录、换服和退出产生迟到回写。
    private func begin(offlineMeansStoredLogin: Bool = false, _ action: @escaping @MainActor (MobileAccountClient) async throws -> Void) {
        guard !busy else { return }
        let client: MobileAccountClient
        do { client = try self.client() } catch { notice = error.localizedDescription; return }
        busy = true; notice = nil
        operation = Task {
            defer { self.busy = false; self.operation = nil }
            do { try await action(client) }
            catch MobileAccountError.notAuthenticated {
                self.session = nil
                self.loginNeedsVerification = false
                self.notice = nil
            } catch MobileAccountError.unavailable {
                self.loginNeedsVerification = self.hasLogin || offlineMeansStoredLogin
                self.notice = MobileAccountError.unavailable.localizedDescription
            } catch MobileAccountError.alreadyAuthenticated {
                // 本地存在凭据但远端状态未核实时，仍须保留本端退出入口。
                self.loginNeedsVerification = true
                self.notice = MobileAccountError.alreadyAuthenticated.localizedDescription
            } catch let error as MobileAccountError where error == .timedOut || error == .invalidResponse {
                // 无回执不能证明凭据未写入；保留核实和退出入口，不自动重试登录。
                self.loginNeedsVerification = self.hasLogin || offlineMeansStoredLogin
                self.notice = error.localizedDescription
            } catch is CancellationError {
                self.loginNeedsVerification = self.hasLogin || offlineMeansStoredLogin
                self.notice = "操作已取消，请刷新核实当前登录状态。"
            } catch { self.notice = error.localizedDescription }
        }
    }
}
