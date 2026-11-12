import XCTest
import Foundation
@testable import CodexTop
@testable import CodexTopCore

/// REQ-005 接口服务：只在本机回环上起服务（不打开局域网、不广播），内容用假的，测收发、错误码和口令。
@MainActor final class DeviceAPIServerTests: XCTestCase {
    private func makeServer(token: String? = nil, viaLAN: Bool = false) async throws -> (DeviceAPIServer, UInt16) {
        let server = DeviceAPIServer(content: { route in Data("{\"route\":\"\(route.rawValue)\"}".utf8) },
                                     open: { code, reply in
                                         // 假的打开：abc123 能打开，abc124 打不开，其他找不到。
                                         switch code {
                                         case "abc123": reply(200, Data("{\"opened\":true}".utf8))
                                         case "abc124": reply(502, Data("{\"opened\":false,\"message\":\"无法打开\"}".utf8))
                                         default: reply(404, Data("{\"error\":\"not_found\"}".utf8))
                                         }
                                     })
        server.treatsLoopbackAsLAN = viaLAN
        server.apply(.init(lan: false, token: token, port: 0, serviceName: "测试"))
        for _ in 0..<100 where server.boundPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(server.boundPort)
        XCTAssertNil(server.problem)
        return (server, port)
    }

    private func get(_ port: UInt16, _ path: String, method: String = "GET", headers: [String: String] = [:]) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 5
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    func testRoutesAndErrors() async throws {
        let (server, port) = try await makeServer()
        defer { server.stop() }
        for route in DeviceAPIServer.Route.allCases {
            let (code, body) = try await get(port, route.rawValue)
            XCTAssertEqual(code, 200)
            XCTAssertEqual(body, "{\"route\":\"\(route.rawValue)\"}")
        }
        // 带查询参数也认得出地址。
        let (queried, _) = try await get(port, "/api/v1/status?x=1")
        XCTAssertEqual(queried, 200)
        let (missing, missingBody) = try await get(port, "/api/v1/nope")
        XCTAssertEqual(missing, 404)
        XCTAssertTrue(missingBody.contains("not_found"))
        let (post, _) = try await get(port, "/api/v1/status", method: "POST")
        XCTAssertEqual(post, 405)
        let (big, _) = try await get(port, "/api/v1/status", headers: ["X-Padding": String(repeating: "a", count: 9 * 1024)])
        XCTAssertEqual(big, 431)
    }

    func testOpenTaskMethodsAndResults() async throws {
        let (server, port) = try await makeServer()
        defer { server.stop() }
        let (opened, openedBody) = try await get(port, "/api/v1/tasks/abc123/open", method: "POST")
        XCTAssertEqual(opened, 200)
        XCTAssertEqual(openedBody, "{\"opened\":true}")
        let (failed, failedBody) = try await get(port, "/api/v1/tasks/ABC124/open", method: "POST")
        XCTAssertEqual(failed, 502)
        XCTAssertTrue(failedBody.contains("无法打开"))
        let (missing, _) = try await get(port, "/api/v1/tasks/ffff/open", method: "POST")
        XCTAssertEqual(missing, 404)
        // 读取方式请求打开地址、提交方式请求读取地址都不允许；编号不是十六进制当成不存在的地址。
        let (readOpen, _) = try await get(port, "/api/v1/tasks/abc123/open")
        XCTAssertEqual(readOpen, 405)
        let (postTheme, _) = try await get(port, "/api/v1/theme", method: "POST")
        XCTAssertEqual(postTheme, 405)
        let (badCode, _) = try await get(port, "/api/v1/tasks/zz/open", method: "POST")
        XCTAssertEqual(badCode, 404)
        XCTAssertEqual(DeviceAPIServer.openCode("/api/v1/tasks/3f9a1c0b7d2e/open"), "3f9a1c0b7d2e")
        XCTAssertNil(DeviceAPIServer.openCode("/api/v1/tasks/3f9a/open/x"))
    }

    func testLocalRequestsNeedNoToken() async throws {
        let (server, port) = try await makeServer(token: "123456")
        defer { server.stop() }
        let (code, _) = try await get(port, "/api/v1/tasks")
        XCTAssertEqual(code, 200)
    }

    func testLANTokenAndLockout() async throws {
        let (server, port) = try await makeServer(token: "123456", viaLAN: true)
        defer { server.stop() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        server.now = { clock }
        let right = ["Authorization": "Bearer 123456"], wrong = ["Authorization": "Bearer 654321"]
        let (none, noneBody) = try await get(port, "/api/v1/status")
        XCTAssertEqual(none, 401)
        XCTAssertFalse(noneBody.contains("route"))
        let (ok, _) = try await get(port, "/api/v1/status", headers: right)
        XCTAssertEqual(ok, 200)
        // 没口令时连地址存不存在都不告诉；打开任务也要口令。
        let (hidden, _) = try await get(port, "/api/v1/nope")
        XCTAssertEqual(hidden, 401)
        let (openNoToken, _) = try await get(port, "/api/v1/tasks/abc123/open", method: "POST")
        XCTAssertEqual(openNoToken, 401)
        let (openWithToken, _) = try await get(port, "/api/v1/tasks/abc123/open", method: "POST", headers: right)
        XCTAssertEqual(openWithToken, 200)

        // 连续错 5 次，1 分钟内带对的也拒绝，过后恢复。
        for _ in 0..<5 {
            let (code, _) = try await get(port, "/api/v1/status", headers: wrong)
            XCTAssertEqual(code, 401)
        }
        let (locked, _) = try await get(port, "/api/v1/status", headers: right)
        XCTAssertEqual(locked, 401)
        clock = clock.addingTimeInterval(61)
        let (unlocked, _) = try await get(port, "/api/v1/status", headers: right)
        XCTAssertEqual(unlocked, 200)

        // 换口令后旧口令立刻失效，不用重开服务。
        server.apply(.init(lan: false, token: "000111", port: 0, serviceName: "测试"))
        let (old, _) = try await get(port, "/api/v1/status", headers: right)
        XCTAssertEqual(old, 401)
        let (new, _) = try await get(port, "/api/v1/status", headers: ["Authorization": "Bearer 000111"])
        XCTAssertEqual(new, 200)
    }
}
