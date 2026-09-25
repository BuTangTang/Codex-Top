import XCTest
import Foundation
@testable import CodexTopCore

final class MobileAccountClientTests: XCTestCase, @unchecked Sendable {
    /// 服务配置拒绝明文公网、内嵌凭据和查询串，开发回环须明确允许。
    func testServiceValidationKeepsCredentialsOffUntrustedAddresses() throws {
        let home = URL(fileURLWithPath: "/tmp/synthetic-codextop")
        for address in ["http://example.com", "https://user:pass@example.com", "https://example.com?token=x", "https://example.com/#x", "https://example.com/path", "http://127.0.0.1:3009"] {
            XCTAssertThrowsError(try MobileAccountConfiguration(serverAddress: address, home: home, executable: nil))
        }
        let local = try MobileAccountConfiguration(serverAddress: "http://127.0.0.1:3009/", home: home, executable: nil, allowLoopback: true)
        XCTAssertEqual(local.serverURL.absoluteString, "http://127.0.0.1:3009")
        XCTAssertEqual(local.environment["HAPPIER_HOME_DIR"], home.path)
        XCTAssertNotEqual(local.environment["HAPPIER_ACTIVE_SERVER_ID"], try MobileAccountConfiguration(serverAddress: "https://example.com", home: home, executable: nil).environment["HAPPIER_ACTIVE_SERVER_ID"])
    }

    /// 同一规范化地址跨配置实例与产品目录保持身份，避免重启后改用另一份凭据。
    func testServerIdentityIsStableForCanonicalAddress() throws {
        let expected = "codextop_100680ad546ce6a577f42f52df33b4cfdca756859e664b8d7de329b"
        for (index, address) in ["https://example.com", "https://example.com/", "  https://example.com/\n"].enumerated() {
            let configuration = try MobileAccountConfiguration(
                serverAddress: address,
                home: URL(fileURLWithPath: "/tmp/synthetic-codextop-\(index)"),
                executable: nil
            )
            XCTAssertEqual(configuration.environment["HAPPIER_ACTIVE_SERVER_ID"], expected)
        }
    }

    /// 对齐连接组件的文件系统标识契约，且不同服务地址与端口不能共享账号目录。
    func testServerIdentityFitsCliFilesystemContractAndSeparatesServices() throws {
        let addresses = ["https://example.com", "https://other.example.com", "https://example.com:8443", "http://127.0.0.1:3009", "http://127.0.0.1:3010"]
        var identities = Set<String>()
        for address in addresses {
            let configuration = try MobileAccountConfiguration(
                serverAddress: address,
                home: URL(fileURLWithPath: "/tmp/synthetic-codextop"),
                executable: nil,
                allowLoopback: true
            )
            let identity = try XCTUnwrap(configuration.environment["HAPPIER_ACTIVE_SERVER_ID"])
            // CLI isServerIdFilesystemSafe 只接受 1...64 个 ASCII 字母、数字、点、下划线和短横线。
            XCTAssertLessThanOrEqual(identity.utf8.count, 64)
            XCTAssertNotNil(identity.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression))
            XCTAssertTrue(identity.hasPrefix("codextop_"))
            XCTAssertTrue(identities.insert(identity).inserted, "Different services must keep separate identities")
        }
    }

    /// 真实子进程捕获合成输入，验证密码只经过 stdin 且状态经过协议解码。
    func testLoginUsesStdinAndStatusUsesVerifiedIdentity() async throws {
        let root = try fixture(script: #"""
        printf '%s\n' "$@" > "$HAPPIER_HOME_DIR/arguments"
        cat > "$HAPPIER_HOME_DIR/input"
        if [ "$2" = 'password-login' ]; then
          printf '%s\n' '{"v":1,"kind":"auth_password_login","ok":true,"data":{"authenticated":true,"accountId":"account-a"}}'
        else
          printf '%s\n' '{"v":1,"kind":"auth_status","ok":true,"data":{"authenticated":true,"accountId":"account-a","loginName":"alice","machineRegistered":true,"daemonRunning":false,"host":"Test Mac"}}'
        fi
        """#)
        let client = try client(root)
        try await client.login(name: "alice", password: "synthetic-password")
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
        XCTAssertFalse(arguments.contains("synthetic-password"))
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("input"))) as? [String: String]
        XCTAssertEqual(input?["password"], "synthetic-password")
        let session = try await client.status()
        XCTAssertEqual(session.accountId, "account-a")
        XCTAssertEqual(session.loginName, "alice")
        XCTAssertEqual(session.daemonRunning, false)
    }

    /// 离线、错密、账号归属冲突和畸形回执分别处理，不回显后端秘密。
    func testErrorResponsesAreRedactedAndDoNotInventSignOut() async throws {
        for (code, expected) in [("auth_unavailable", MobileAccountError.unavailable), ("invalid_credentials", .invalidCredentials), ("source_account_conflict", .sourceConflict), ("not_authenticated", .notAuthenticated)] {
            let root = try fixture(script: "cat >/dev/null\nprintf '%s\\n' '{\"v\":1,\"kind\":\"auth_status\",\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"synthetic-private-secret\"}}'\nexit 1")
            do { _ = try await client(root).status(); XCTFail("Expected error") }
            catch {
                XCTAssertEqual(error as? MobileAccountError, expected)
                XCTAssertFalse(error.localizedDescription.contains("synthetic-private-secret"))
            }
        }
        let malformed = try fixture(script: "cat >/dev/null\nprintf '%s\\n' '{\"v\":1,\"kind\":\"wrong_kind\",\"ok\":true}'")
        do { _ = try await client(malformed).status(); XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? MobileAccountError, .invalidResponse) }
    }

    /// 取消或超时后只回收本次拥有的组件进程，不遗留无主认证操作。
    func testCancellationAndTimeoutReapOwnedCommand() async throws {
        let root = try fixture(script: #"""
        printf '%s' "$$" > "$HAPPIER_HOME_DIR/pid"
        cat >/dev/null
        exec /bin/sleep 20
        """#)
        let short = try client(root, timeout: 1)
        do { _ = try await short.status(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? MobileAccountError, .timedOut) }
        try assertReaped(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("pid"))
        let task = Task { try await self.client(root).status() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("pid").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertReaped(root)
    }

    /// 为测试建立独立脚本，不读取真实账号或 Codex 数据。
    private func fixture(script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codextop-account-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("bridge")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// 把产品 CLI 边界替换为测试脚本，保留真实进程和管道实现。
    private func client(_ root: URL, timeout: TimeInterval = 10) throws -> MobileAccountClient {
        MobileAccountClient(configuration: try MobileAccountConfiguration(serverAddress: "https://example.com", home: root, executable: root.appendingPathComponent("bridge")), timeout: timeout)
    }

    /// 通过进程标识确认已经回收，而不是只收到取消错误。
    private func assertReaped(_ root: URL) throws {
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
    }
}
