import Foundation
import Darwin

/// REQ-003 层 A：读取本机 Claude Code 会话记录，输出只有任务、没有额度的快照。
/// 只列 `projects/<项目>/<会话>.jsonl` 这一层；文件修改时间只用来决定要不要读，不用于显示（设计 3.1）。
public actor ClaudeCodeSource {
    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static let tailBytes = 64 * 1024
    static let coldReadLimit = 8 * 1024 * 1024
    static let recentWindow: TimeInterval = 30 * 86_400
    static let maximumSessions = 500

    private struct Tail {
        var size: UInt64
        var offset: UInt64
        var reducer: ClaudeTranscriptReducer
    }

    private let root: URL
    private let readRegistry: @Sendable (URL) -> ClaudeSessionRegistry
    /// 层 C：Codex Top 钩子写的事件目录；没装钩子时目录里没有文件，状态只看记录和登记。
    private let hookEvents: URL?
    /// 同一会话可能在多个项目目录留有副本；增量游标和归约状态只能属于具体文件。
    private var tails: [URL: Tail] = [:]

    public init(root: URL = ClaudeCodeSource.defaultRoot, hookEvents: URL? = nil,
                readRegistry: @escaping @Sendable (URL) -> ClaudeSessionRegistry = { ClaudeSessionRegistry.read(root: $0) }) {
        self.root = root.standardizedFileURL; self.hookEvents = hookEvents; self.readRegistry = readRegistry
    }

    /// 数据目录存在才算装了 Claude Code（R-20）。
    public var installed: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue
    }

    /// 关注或已知存活的会话即使超过 30 天也读；其余只读最近改动的，最多 500 个。
    /// 同编号副本独立读取，按明确事件时间选出整份状态，最终每个会话只生成一个任务。
    public func snapshot(keep keepIDs: Set<String> = [], now: Date = .now) -> SourceSnapshot {
        let registry = readRegistry(root)
        // 进程还在的会话即使很久没改动也要读。
        let liveIDs = Set((registry.entries ?? [:]).values.filter(\.alive).map { "cc:" + $0.sessionID })
        let keepIDs = keepIDs.union(liveIDs)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            // 没装 Claude Code 或还没有会话：不报错、不出现任何任务（R-20）。
            tails.removeAll()
            return SourceSnapshot(tasks: [], observedAt: now)
        }
        var files: [(id: String, url: URL, modified: Date, size: UInt64)] = []
        for dir in projectDirs {
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])) ?? []
            for url in entries where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate,
                      url.standardizedFileURL.path.hasPrefix(root.path + "/") else { continue }
                let id = "cc:" + url.deletingPathExtension().lastPathComponent
                guard keepIDs.contains(id) || now.timeIntervalSince(modified) <= Self.recentWindow else { continue }
                files.append((id, url, modified, UInt64(values.fileSize ?? 0)))
            }
        }
        files.sort { $0.modified > $1.modified }
        if files.count > Self.maximumSessions {
            let kept = files.filter { keepIDs.contains($0.id) }
            let rest = files.filter { !keepIDs.contains($0.id) }.prefix(max(0, Self.maximumSessions - kept.count))
            files = kept + rest
        }
        var tasks: [CodexTask] = []
        var taskIndices: [String: Int] = [:]
        var bytesRead = 0
        var seen: Set<URL> = []
        for file in files {
            seen.insert(file.url)
            let (reducer, read) = advance(url: file.url, size: file.size)
            bytesRead += read
            let created = reducer.firstEventAt ?? reducer.activity.lastEventAt ?? file.modified
            let updated = reducer.activity.lastEventAt ?? created
            let project = reducer.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let entry = registry.entries?[String(file.id.dropFirst(3))]
            let name = entry?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            var task = CodexTask(id: file.id, title: reducer.title ?? (name?.isEmpty == false ? name! : "未命名会话"), project: project,
                                 createdAt: created, updatedAt: updated, rolloutURL: file.url, origin: .claudeCode)
            task.claudeLaunch = entry.map { ClaudeLaunch(fromDesktopApp: $0.fromDesktopApp, hostSessionID: $0.hostSessionID) }
            var activity = reducer.activity
            if let hookEvents, activity.phase == .running {
                activity = ClaudeHookEvents.apply(ClaudeHookEvents.latest(directory: hookEvents, session: String(file.id.dropFirst(3))), to: activity)
            }
            // 记录显示还在运行或等待，但登记里进程已经没了：会话已退出，不再显示运行（设计 3.4）。
            // 登记目录读不到时无法判断，保持记录得出的状态。
            if registry.entries != nil, activity.phase == .running || activity.phase == .waiting, entry?.alive != true {
                activity.phase = .stopped; activity.detail = "会话已退出"; activity.waitingStartedAt = nil
            }
            task.activity = activity.effective(at: now, sourceName: TaskOrigin.claudeCode.displayName)
            if let index = taskIndices[file.id] {
                // 文件修改时间仅用于读取范围，不能把较晚复制的旧记录当成较新的任务状态。
                let previous = tasks[index]
                let event = task.activity.lastEventAt ?? .distantPast
                let previousEvent = previous.activity.lastEventAt ?? .distantPast
                if event > previousEvent || (event == previousEvent && file.url.path < previous.rolloutURL.path) {
                    tasks[index] = task
                }
            } else {
                taskIndices[file.id] = tasks.count
                tasks.append(task)
            }
        }
        tails = tails.filter { seen.contains($0.key) }
        return SourceSnapshot(tasks: tasks, bytesRead: bytesRead, observedAt: now)
    }

    /// 冷启动先读尾部 64 KiB；尾部只有附件、请求快照这类大行而没有对话行时，往前加读到最多 8 MiB。
    /// 之后只读新增的部分。文件变短（被重写）时重新冷启动。
    private func advance(url: URL, size: UInt64) -> (ClaudeTranscriptReducer, Int) {
        if let existing = tails[url], size >= existing.offset {
            if size == existing.size { return (existing.reducer, 0) }
            var tail = existing
            let read = consume(url: url, from: tail.offset, into: &tail.reducer, dropFirstLine: false)
            tail.offset += UInt64(read.consumed); tail.size = size
            tails[url] = tail
            return (tail.reducer, read.bytes)
        }
        var window = UInt64(Self.tailBytes), bytes = 0
        while true {
            let start = size > window ? size - window : 0
            var reducer = ClaudeTranscriptReducer()
            let read = consume(url: url, from: start, into: &reducer, dropFirstLine: start > 0)
            bytes += read.bytes
            if reducer.firstEventAt != nil || start == 0 || window >= UInt64(Self.coldReadLimit) {
                tails[url] = Tail(size: size, offset: start + UInt64(read.consumed), reducer: reducer)
                return (reducer, bytes)
            }
            window *= 4
        }
    }

    /// 从 offset 读到文件末尾，只消费到最后一个换行；之后的半行还在写，留到下次。
    /// 冷启动起点落在行中间时，第一段不完整，跳过。
    private func consume(url: URL, from offset: UInt64, into reducer: inout ClaudeTranscriptReducer, dropFirstLine: Bool) -> (consumed: Int, bytes: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        let consumed = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
            var start = 0, skip = dropFirstLine
            // 按字节搜索换行，逐行处理；不建立整批 Data 切片数组，也不重复扫描整批内容。
            while let newline = memchr(base.advanced(by: start), 10, buffer.count - start) {
                let end = base.distance(to: newline)
                if !skip && end > start {
                    // Foundation 的 JSON 临时对象在本行释放，避免一次追加积累到整轮读取结束。
                    autoreleasepool { reducer.consume(Data(bytes: base.advanced(by: start), count: end - start)) }
                }
                skip = false
                start = end + 1
            }
            // 最后一行尚无换行时不推进游标，下一轮从这里接着读取。
            return start
        }
        return (consumed, data.count)
    }
}
