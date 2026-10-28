import Foundation
import CSQLite
import Darwin

public actor LocalCodexSource {
    public let root: URL
    private var tails: [String: IncrementalRollout] = [:]
    private var recoveryCursor = 0
    private let compressed = CompressedRolloutReader()
    private let replySource: DesktopReplyReceiptSource
    private var receivedReplies: [String: QuestionReplyReceipt] = [:]
    private var labels: [String: TaskLabels] = [:]
    private var labelUTF8Bytes = 0
    // 只复用 URL 值对象；每轮仍重新核实父目录和末级文件类型，不缓存文件状态。
    private var recordURLValues: [String: URL] = [:]

    /// 同轮记录共用已解析父目录；末级链接仍完整解析，缓存不跨快照保留。
    private func resolvedRecordURL(_ path: String, parents: inout [String: URL]) -> (url: URL, error: Int32) {
        // 不拆分全部路径分量，也不为每条记录构造中间 NSURL。
        guard path.hasPrefix("/"), !path.hasSuffix("/"),
              path.withCString({ strstr($0, "/../") == nil && strstr($0, "/./") == nil }),
              !path.hasSuffix("/.."), !path.hasSuffix("/."),
              let slash = path.utf8.lastIndex(of: 47) else {
            return inspectRecordURL(URL(fileURLWithPath: path, isDirectory: false).resolvingSymlinksInPath())
        }
        let parentPath = slash == path.startIndex ? "/" : String(path[..<slash])
        let resolved: URL
        if let cached = parents[parentPath] {
            resolved = cached
        } else {
            resolved = URL(fileURLWithPath: parentPath, isDirectory: true).resolvingSymlinksInPath()
            var parentInfo = stat()
            guard resolved.path.withCString({ stat($0, &parentInfo) }) == 0,
                  (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
                return inspectRecordURL(URL(fileURLWithPath: path, isDirectory: false).resolvingSymlinksInPath())
            }
            parents[parentPath] = resolved
        }
        let leaf = String(path[path.index(after: slash)...])
        let candidatePath = (resolved.path == "/" ? "/" : resolved.path + "/") + leaf
        let candidate: URL
        if let cached = recordURLValues[candidatePath] { candidate = cached }
        else {
            candidate = URL(fileURLWithPath: candidatePath, isDirectory: false)
            // 数量与单项长度同时设限，避免长期运行时积累任意历史路径。
            if recordURLValues.count < 4096 && candidatePath.utf8.count <= 1024 {
                recordURLValues[candidatePath] = candidate
            }
        }
        var info = stat()
        let result = candidate.path.withCString { lstat($0, &info) }
        // 悬空或有效的末级符号链接均交回原解析器，保留目录边界与恢复行为。
        if result == 0 && (info.st_mode & S_IFMT) == S_IFREG { return (candidate, 0) }
        // 已核实父目录存在时，缺失末级文件不需要重新遍历所有祖先。
        if result != 0 && errno == ENOENT { return (candidate, ENOENT) }
        return inspectRecordURL(URL(fileURLWithPath: path, isDirectory: false).resolvingSymlinksInPath())
    }

    /// 返回本次解析时的文件可达性，调用处复用同一次检查，避免再做一次系统调用。
    private func inspectRecordURL(_ url: URL) -> (url: URL, error: Int32) {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        return (url, result == 0 ? 0 : errno)
    }

    /// 只保存纯文本的解析结果；原始字段改变即重算，不缓存路径、文件或活动状态。
    private struct TaskLabels {
        let rawTitle: String
        let rawSource: String?
        let title: String
        let parentID: String?
        let retainedUTF8Bytes: Int
    }

    /// 主查询固定七列，只保存当轮文本值，保留 NULL 与字段缺省处理的边界。
    private struct ThreadRow {
        let id: String?
        let title: String?
        let cwd: String?
        let rolloutPath: String?
        let createdAt: String?
        let updatedAt: String?
        let source: String?

        /// 下一次 step 前复制 SQLite 文本，沿用 C 字符串转换，不改为数值或二进制解码。
        init(statement: OpaquePointer?) {
            id = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            cwd = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            rolloutPath = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            createdAt = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            updatedAt = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            source = sqlite3_column_text(statement, 6).map { String(cString: $0) }
        }
    }

    /// 数据库、历史和桌面接收证据使用同一根目录，切换数据源时不会串用回执。
    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        replySource = DesktopReplyReceiptSource(root: self.root)
    }
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    /// 先读取正式任务状态，再为关注中的待答任务核实桌面已接收的回答；辅助通道失败不影响主数据源。
    public func snapshot(now: Date = .now, recoverTimingFor rootIDs: Set<String> = [], monitoredRootIDs: Set<String>? = nil) async throws -> SourceSnapshot {
        let database = try databaseURL()
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }; throw CodexSourceError.databaseUnavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 300)
        let columns = Set(try query(connection, "PRAGMA table_info(threads)").compactMap { $0["name"] })
        guard Set(["id", "title", "cwd", "rollout_path", "created_at", "updated_at", "archived"]).isSubset(of: columns) else { throw CodexSourceError.incompatibleDatabase }
        let title = columns.contains("name") ? "COALESCE(NULLIF(name,''),title)" : "title"
        let source = columns.contains("source") ? "source" : "'' AS source"
        let rows = try queryThreadRows(connection, "SELECT id,\(title) AS title,cwd,rollout_path,created_at,updated_at,\(source) FROM threads WHERE archived=0 ORDER BY updated_at DESC")
        let tables = try query(connection, "SELECT name FROM sqlite_master WHERE type='table'")
        var parents: [String: String] = [:]
        if tables.contains(where: { $0["name"] == "thread_spawn_edges" }) {
            for edge in (try? query(connection, "SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges")) ?? [] {
                if let child = edge["child_thread_id"], let parent = edge["parent_thread_id"] { parents[child] = parent }
            }
        }
        var tasks: [CodexTask] = [], quota: QuotaSnapshot?, bytes = 0
        var failures: Set<String> = []
        var compressedCandidates: [String: URL] = [:]
        var projectNames: [String: String] = [:]
        var resolvedParents: [String: URL] = [:]
        let rootPrefix = root.path + "/"
        for row in rows {
            guard let id = row.id, let path = row.rolloutPath else { continue }
            let location = resolvedRecordURL(path, parents: &resolvedParents)
            let file = location.url
            let explicitParent = parents[id]
            // 有正式父子边时沿用原短路规则，不再额外解析可能很长的来源 JSON。
            let label = taskLabels(id: id, title: row.title ?? "", source: explicitParent == nil ? row.source : nil)
            // 同一快照中相同原始项目路径只派生一次名称，下一轮仍按当前字段重建。
            let cwd = row.cwd ?? ""
            let project = projectNames[cwd] ?? URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
            projectNames[cwd] = project
            var task = CodexTask(id: id, title: label.title, project: project,
                                 createdAt: Date(timeIntervalSince1970: Double(row.createdAt ?? "") ?? 0),
                                 updatedAt: Date(timeIntervalSince1970: Double(row.updatedAt ?? "") ?? 0),
                                 parentID: explicitParent ?? label.parentID, rolloutURL: file)
            if !file.path.hasPrefix(rootPrefix) {
                task.activity.detail = "记录位于数据目录之外，未读取"; failures.insert(id)
            } else {
                let missing = location.error == ENOENT
                if missing {
                    let siblingLocation = resolvedRecordURL(path + ".zst", parents: &resolvedParents)
                    let sibling = siblingLocation.url
                    guard sibling.path.hasPrefix(rootPrefix) else {
                        task.activity = TaskActivity(detail: "记录位于数据目录之外，未读取")
                        failures.insert(id); tails.removeValue(forKey: id); compressed.forget(id)
                        tasks.append(task); continue
                    }
                    if siblingLocation.error == EACCES || siblingLocation.error == EPERM {
                        task.activity = TaskActivity(detail: "无权读取任务记录")
                        failures.insert(id); tails.removeValue(forKey: id); compressed.forget(id)
                        tasks.append(task); continue
                    }
                    if siblingLocation.error == 0 {
                        compressedCandidates[id] = sibling
                        tails.removeValue(forKey: id)
                        task.activity = TaskActivity(detail: "历史记录已压缩，尚未读取")
                        tasks.append(task)
                        continue
                    }
                }
                compressed.forget(id)
                var tail = tails[id] ?? IncrementalRollout()
                do {
                    bytes += try tail.refresh(url: file)
                    task.activity = tail.reducer.activity.effective(at: now)
                    if !tail.isCaughtUp {
                        task.activity.phase = .unknown
                        task.activity.detail = "正在同步任务活动…"
                    }
                    if let candidate = tail.reducer.quota, quota == nil || candidate.observedAt > quota!.observedAt { quota = candidate }
                    tails[id] = tail
                } catch {
                    let nsError = error as NSError
                    let permission = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
                        || (nsError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(nsError.code))
                    task.activity = TaskActivity(detail: permission ? "无权读取任务记录" : missing ? "任务记录缺失" : "暂时无法读取任务记录")
                    tails.removeValue(forKey: id); failures.insert(id)
                }
            }
            tasks.append(task)
        }
        // 本轮仅复用不会被计时恢复改变的祖先映射，后续活动状态仍从当前 tasks 读取。
        let taskRootIDs = TaskGraph.resolveRootIDs(tasks: tasks)
        let monitored = monitoredRootIDs ?? rootIDs
        let selectedIDs = Set(tasks.filter { monitored.contains(taskRootIDs[$0.id] ?? $0.id) }.map(\.id))
        let compressedIDs = selectedIDs.intersection(compressedCandidates.keys)
        compressed.beginCycle(ids: compressedIDs)
        var reading = 0, limited = 0
        let ordered = tasks.indices.filter { compressedIDs.contains(tasks[$0].id) }.sorted {
            let leftRoot = monitored.contains(tasks[$0].id), rightRoot = monitored.contains(tasks[$1].id)
            return leftRoot != rightRoot ? leftRoot : tasks[$0].updatedAt > tasks[$1].updatedAt
        }
        for index in ordered {
            let id = tasks[index].id
            guard let url = compressedCandidates[id] else { continue }
            let result = compressed.read(id: id, url: url, now: now)
            tasks[index].activity = result.activity; bytes += result.bytes
            switch result.category {
            case .reading: reading += 1
            case .limited: limited += 1
            case .unavailable: failures.insert(id)
            case .ready: break
            }
            if let candidate = result.quota, quota == nil || candidate.observedAt > quota!.observedAt { quota = candidate }
        }
        if !rootIDs.isEmpty {
            let candidates = tasks.indices.filter { index in
                let task = tasks[index]
                guard rootIDs.contains(taskRootIDs[task.id] ?? task.id), let tail = tails[task.id] else { return false }
                return tail.reducer.activity.startedAt == nil && (tail.reducer.activity.phase == .running || tail.reducer.activity.phase == .waiting)
            }
            var remaining = 8 * 1_024 * 1_024
            let first = candidates.isEmpty ? 0 : recoveryCursor % candidates.count
            for distance in 0..<candidates.count {
                guard remaining >= 1_024 else { break }
                let index = candidates[(first + distance) % candidates.count]
                let task = tasks[index]
                guard var tail = tails[task.id] else { continue }
                // Timing recovery is optional: an unavailable historical range
                // must not replace a successfully read current task state. Share
                // 8 MiB across the snapshot, at most 4 MiB per task, and rotate
                // the first candidate so many selected tasks cannot starve later ones.
                let recoveredBytes = (try? tail.recoverTiming(url: task.rolloutURL, maximumBytes: min(4 * 1_024 * 1_024, remaining))) ?? 0
                bytes += recoveredBytes; remaining -= recoveredBytes
                recoveryCursor = (first + distance + 1) % candidates.count
                tails[task.id] = tail
                if tail.isCaughtUp { tasks[index].activity = tail.reducer.activity.effective(at: now) }
            }
        }
        let pending = Dictionary(uniqueKeysWithValues: tasks.compactMap { task -> (String, Date)? in
            guard rootIDs.contains(taskRootIDs[task.id] ?? task.id), task.activity.phase == .waiting else { return nil }
            let since = tails[task.id].flatMap { $0.isCaughtUp ? $0.reducer.awaitingReplySince : nil } ?? compressed.awaitingReplySince(task.id)
            return since.map { (task.id, $0) }
        })
        // 只缓存已核实的编号和时间；正式输入/新轮次清除问题后同步丢弃旧回执。
        receivedReplies = receivedReplies.filter { _, reply in
            pending[reply.threadID].map { reply.receivedAt >= $0 } ?? false
        }
        if !pending.isEmpty {
            let knownReplies = Array(receivedReplies.values)
            let needsReceipt = pending.filter { id, _ in
                (tails[id]?.reducer.activity(acknowledging: knownReplies, for: id, at: now) ?? compressed.projectedActivity(id, receipts: knownReplies, now: now))?.phase == .waiting
            }
            for reply in await replySource.receipts(for: needsReceipt, now: now) {
                guard pending[reply.threadID].map({ reply.receivedAt >= $0 }) == true else { continue }
                receivedReplies[reply.threadID + ":" + reply.clientID] = reply
            }
            if receivedReplies.count > 1_024 {
                // 异常重复提交也不能让辅助缓存无限增长；被淘汰证据仍可由正式记录确认。
                receivedReplies = Dictionary(uniqueKeysWithValues: receivedReplies.sorted {
                    $0.value.receivedAt == $1.value.receivedAt ? $0.key < $1.key : $0.value.receivedAt > $1.value.receivedAt
                }.prefix(1_024).map { ($0.key, $0.value) })
            }
            for index in tasks.indices where pending[tasks[index].id] != nil {
                let task = tasks[index]
                guard var tail = tails[task.id] else {
                    if let url = compressedCandidates[task.id] {
                        let refreshed = compressed.read(id: task.id, url: url, now: now)
                        tasks[index].activity = refreshed.category == .ready
                            ? (compressed.projectedActivity(task.id, receipts: Array(receivedReplies.values), now: now) ?? refreshed.activity)
                            : refreshed.activity
                        bytes += refreshed.bytes
                    }
                    continue
                }
                // IPC 等待期间可能写入正式回复、停止或新问题，重新读取后才投影，正式事件始终优先。
                do {
                    bytes += try tail.refresh(url: task.rolloutURL)
                    tails[task.id] = tail
                    if tail.isCaughtUp {
                        tasks[index].activity = tail.reducer.activity(acknowledging: Array(receivedReplies.values), for: task.id, at: now)
                    } else {
                        tasks[index].activity = TaskActivity(detail: "正在同步任务活动…")
                    }
                } catch {
                    tasks[index].activity = TaskActivity(detail: "暂时无法读取任务记录")
                    tails.removeValue(forKey: task.id)
                    failures.insert(task.id)
                }
            }
        }
        let ids = Set(tasks.map(\.id))
        // 完整保留时不重建尾部字典；删除失效项或清空缓存仍沿用原 filter 的缩容行为。
        if tails.isEmpty || tails.keys.contains(where: { !ids.contains($0) }) {
            tails = tails.filter { ids.contains($0.key) }
        }
        for id in labels.keys.filter({ !ids.contains($0) }) { removeCachedLabel(for: id) }
        // 显式关注范围用于正式界面；旧只读调用保持普通文件诊断兼容，不自动解压全库。
        let failureCount = monitoredRootIDs == nil && rootIDs.isEmpty ? failures.count : failures.intersection(selectedIDs).count
        var reasons: [String] = []
        if failureCount > 0 { reasons.append("\(failureCount) 条记录不可用") }
        if reading > 0 { reasons.append("\(reading) 条读取中") }
        if limited > 0 { reasons.append("\(limited) 条受限") }
        let warning = reasons.isEmpty ? nil : (monitoredRootIDs == nil && rootIDs.isEmpty ? "记录检查：" : "关注范围：") + reasons.joined(separator: "，")
        return SourceSnapshot(tasks: tasks, quota: quota, warning: warning, bytesRead: bytes, observedAt: now)
    }
    /// 按完整字段复用纯文本；最多2048项、单项原文4KiB，所有保留字符串的UTF8合计不超过1MiB。
    private func taskLabels(id: String, title: String, source: String?) -> TaskLabels {
        if let cached = labels[id], cached.rawTitle == title, cached.rawSource == source { return cached }
        // 字段变化先释放旧占用；新内容超预算时仍返回当前解析值，不留下过期标签。
        removeCachedLabel(for: id)
        let cleanedTitle = Self.cleanTitle(title), parentID = Self.parentFromSource(source)
        let rawBytes = title.utf8.count + (source?.utf8.count ?? 0)
        let retainedBytes = id.utf8.count + rawBytes + cleanedTitle.utf8.count + (parentID?.utf8.count ?? 0)
        let value = TaskLabels(rawTitle: title, rawSource: source, title: cleanedTitle, parentID: parentID, retainedUTF8Bytes: retainedBytes)
        if rawBytes <= 4_096, labels.count < 2_048, retainedBytes <= 1_048_576 - labelUTF8Bytes {
            labels[id] = value
            labelUTF8Bytes += retainedBytes
        }
        return value
    }
    /// 统一更新缓存的文本预算，任务归档与字段替换都按实际保留项扣减一次。
    private func removeCachedLabel(for id: String) {
        if let previous = labels.removeValue(forKey: id) { labelUTF8Bytes -= previous.retainedUTF8Bytes }
    }
    private func databaseURL() throws -> URL {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { throw CodexSourceError.missingDatabase }
        let candidates: [(Int, URL)] = files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }
        guard let url = candidates.max(by: { $0.0 < $1.0 })?.1 else { throw CodexSourceError.missingDatabase }
        return url
    }
    /// 仅物化固定主查询的行，结束后再读取边表与任务记录；每轮独立 prepare，并保留原错误分类。
    private func queryThreadRows(_ database: OpaquePointer?, _ sql: String) throws -> [ThreadRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw CodexSourceError.incompatibleDatabase }
        defer { sqlite3_finalize(statement) }
        var rows: [ThreadRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw CodexSourceError.databaseUnavailable }
            rows.append(ThreadRow(statement: statement))
        }
        return rows
    }
    /// 每条查询在首行产生后读取列名与原索引，保留自动重编译、NULL 与别名覆盖语义。
    private func query(_ database: OpaquePointer?, _ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw CodexSourceError.incompatibleDatabase }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        var columns: [(index: Int32, name: String)]?
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw CodexSourceError.databaseUnavailable }
            if columns == nil {
                // prepare 后第一次 step 可能自动重编译；此时再读取列信息，且不跨查询保存。
                columns = (0..<sqlite3_column_count(statement)).compactMap { index in
                    guard let name = sqlite3_column_name(statement, index) else { return nil }
                    return (index, String(cString: name))
                }
            }
            let currentColumns = columns ?? []
            var row = [String: String](minimumCapacity: currentColumns.count)
            for column in currentColumns {
                if let text = sqlite3_column_text(statement, column.index) {
                    row[column.name] = String(cString: text)
                }
            }
            rows.append(row)
        }
        return rows
    }
    /// 无换行时省去拆分拼接，Unicode 换行、空白与300字素上限继续沿用原规则。
    private static func cleanTitle(_ title: String) -> String {
        let newlines = CharacterSet.newlines
        let flattened = title.unicodeScalars.contains(where: { newlines.contains($0) })
            ? title.components(separatedBy: newlines).joined(separator: " ") : title
        let cleaned = flattened.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "未命名任务" : String(cleaned.prefix(300))
    }
    /// 仅解析可能为 JSON 对象的来源，仍由原解析器判定嵌套父任务编号。
    private static func parentFromSource(_ source: String?) -> String? {
        // 可解析为对象的 JSON 必有左花括号；普通来源标签无需构造 JSON 错误及缓冲区。
        guard let source, source.utf8.contains(0x7B), let data = source.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagent = value["subagent"] as? [String: Any], let spawn = subagent["thread_spawn"] as? [String: Any] else { return nil }
        return spawn["parent_thread_id"] as? String
    }
}
