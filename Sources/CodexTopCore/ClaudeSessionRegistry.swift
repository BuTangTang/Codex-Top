import Darwin
import Foundation

/// REQ-003 层 B：读取 Claude Code 每个进程留下的运行登记 `sessions/<进程号>.json`。
/// 只用来判断进程还在不在、会话从哪里打开；状态字段不用于判定等待（设计 3.4）。不读同目录的 `.key` 文件。
public struct ClaudeSessionRegistry: Sendable {
    public struct Entry: Equatable, Sendable {
        public var sessionID: String
        public var pid: Int32
        /// 登记写下的进程启动时间，用来排除进程号被复用。
        public var processStart: String
        public var entrypoint: String?
        /// 桌面 App 里的会话编号（`local_…`），用于直达该会话。
        public var hostSessionID: String?
        public var name: String?
        public var alive: Bool
        public var fromDesktopApp: Bool { entrypoint?.hasPrefix("claude-desktop") == true }
    }

    /// 目录不存在时为 nil：无法判断，调用方不得据此改写状态。
    public private(set) var entries: [String: Entry]?

    public init(entries: [String: Entry]?) { self.entries = entries }

    public static func read(root: URL, isAlive: (Int32, String) -> Bool = ClaudeSessionRegistry.processMatches) -> ClaudeSessionRegistry {
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ClaudeSessionRegistry(entries: nil)
        }
        var entries: [String: Entry] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = value["sessionId"] as? String, !session.isEmpty,
                  let pid = (value["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let start = value["procStart"] as? String else { continue }
            let entry = Entry(sessionID: session, pid: pid, processStart: start, entrypoint: value["entrypoint"] as? String,
                              hostSessionID: value["hostSessionId"] as? String, name: value["name"] as? String,
                              alive: isAlive(pid, start))
            // 同一会话有多份登记时，存活的优先。
            if let existing = entries[session], existing.alive, !entry.alive { continue }
            entries[session] = entry
        }
        return ClaudeSessionRegistry(entries: entries)
    }

    /// 进程号存在且启动时间与登记一致（精确到秒）才算存活。
    public static func processMatches(pid: Int32, processStart: String) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return false }
        let started = Date(timeIntervalSince1970: TimeInterval(info.kp_proc.p_starttime.tv_sec))
        return startMatches(started, processStart)
    }

    /// 登记写法同 `ps -o lstart`：`Sun Nov  8 04:09:48 2026`。桌面 App 启动的进程用 UTC 写，
    /// 终端里启动的可能用本地时区，两种都认；比较前把连续空格合并成一个。
    static func startMatches(_ started: Date, _ processStart: String, localZone: TimeZone = .current) -> Bool {
        let recorded = processStart.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return [TimeZone(identifier: "UTC")!, localZone].contains { processStartText(started, zone: $0) == recorded }
    }

    /// 保持 ps 的英文版式；值类型格式化避免每次创建可变 formatter，时区仍由本次调用提供。
    static func processStartText(_ date: Date, zone: TimeZone) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated) \(month: .abbreviated) \(day: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) \(year: .padded(4))",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: zone,
            calendar: Calendar(identifier: .gregorian)
        ))
    }
}
