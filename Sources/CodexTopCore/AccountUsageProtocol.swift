import Foundation
import CoreFoundation

public enum AccountUsageClientError: Error, LocalizedError, Sendable, Equatable {
    case cliUnavailable, timedOut, unavailable, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable: "未找到可用的 Codex CLI，暂时无法读取账户额度。"
        case .timedOut: "读取账户额度超时，请稍后刷新。"
        case .unavailable: "暂时无法读取账户额度，请检查 Codex 登录与网络后重试。"
        case .invalidResponse: "当前 Codex 额度格式不可用，请更新 Codex 或稍后重试。"
        }
    }
}

// Only numeric quota fields leave this boundary. Account IDs, credits, tokens,
// backend error text and unrelated notification payloads are never retained.
enum AccountUsageProtocol {
    static let initialize = Data(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex_top","title":"Codex Top","version":"0.1.0"}}}"#.utf8) + Data([10])
    static let read = Data(#"{"method":"initialized"}"#.utf8) + Data([10])
        + Data(#"{"id":2,"method":"account/rateLimits/read"}"#.utf8) + Data([10])

    static func decodeResult(_ result: [String: Any], at now: Date) throws -> QuotaSnapshot {
        let bucket: [String: Any]
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            // A present multi-bucket view is authoritative. Do not display an
            // unrelated model's quota just because it is the legacy first bucket.
            guard let codex = buckets["codex"] as? [String: Any] else { throw AccountUsageClientError.unavailable }
            bucket = codex
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            bucket = legacy
        } else {
            throw AccountUsageClientError.invalidResponse
        }
        if let id = bucket["limitId"] as? String, id != "codex" { throw AccountUsageClientError.unavailable }
        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
            guard let window = bucket[key] as? [String: Any],
                  let used = number(window["usedPercent"]), used >= 0,
                  let duration = number(window["windowDurationMins"]),
                  let minutes = Int(exactly: duration), minutes > 0 else { return nil }
            let reset = number(window["resetsAt"]).flatMap { value -> Date? in
                guard value >= 0, value <= 253_402_300_799 else { return nil }
                return Date(timeIntervalSince1970: value)
            }
            return QuotaWindow(minutes: minutes, usedPercent: used, resetsAt: reset)
        }
        guard !windows.isEmpty else { throw AccountUsageClientError.unavailable }
        return QuotaSnapshot(observedAt: now, windows: windows, origin: .account)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
