import Foundation
import CSQLite

public actor LocalCodexSource {
    public let root: URL
    private var tails: [String: IncrementalRollout] = [:]
    private var recoveryCursor = 0
    private let replySource: DesktopReplyReceiptSource
    private var receivedReplies: [String: QuestionReplyReceipt] = [:]
    private var labels: [String: TaskLabels] = [:]

    /// 只保存纯文本的解析结果；原始字段改变即重算，不缓存路径、文件或活动状态。
    private struct TaskLabels {
        let rawTitle: String
        let rawSource: String?
        let title: String
        let parentID: String?
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
    public func snapshot(now: Date = .now, recoverTimingFor rootIDs: Set<String> = []) async throws -> SourceSnapshot {
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
        let rows = try query(connection, "SELECT id,\(title) AS title,cwd,rollout_path,created_at,updated_at,\(source) FROM threads WHERE archived=0 ORDER BY updated_at DESC")
        let tables = try query(connection, "SELECT name FROM sqlite_master WHERE type='table'")
        var parents: [String: String] = [:]
        if tables.contains(where: { $0["name"] == "thread_spawn_edges" }) {
            for edge in (try? query(connection, "SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges")) ?? [] {
                if let child = edge["child_thread_id"], let parent = edge["parent_thread_id"] { parents[child] = parent }
            }
        }
        var tasks: [CodexTask] = [], quota: QuotaSnapshot?, bytes = 0, failures = 0
        var projectNames: [String: String] = [:]
        let rootPrefix = root.path + "/"
        for row in rows {
            guard let id = row["id"], let path = row["rollout_path"] else { continue }
            let file = URL(fileURLWithPath: path, isDirectory: false).resolvingSymlinksInPath()
            let explicitParent = parents[id]
            // 有正式父子边时沿用原短路规则，不再额外解析可能很长的来源 JSON。
            let label = taskLabels(id: id, title: row["title"] ?? "", source: explicitParent == nil ? row["source"] : nil)
            // 同一快照中相同原始项目路径只派生一次名称，下一轮仍按当前字段重建。
            let cwd = row["cwd"] ?? ""
            let project = projectNames[cwd] ?? URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
            projectNames[cwd] = project
            var task = CodexTask(id: id, title: label.title, project: project,
                                 createdAt: Date(timeIntervalSince1970: Double(row["created_at"] ?? "") ?? 0),
                                 updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "") ?? 0),
                                 parentID: explicitParent ?? label.parentID, rolloutURL: file)
            if !file.path.hasPrefix(rootPrefix) {
                task.activity.detail = "记录位于数据目录之外，未读取"; failures += 1
            } else {
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
                    task.activity = TaskActivity(detail: "暂时无法读取任务记录")
                    tails.removeValue(forKey: id); failures += 1
                }
            }
            tasks.append(task)
        }
        // 本轮仅复用不会被计时恢复改变的祖先映射，后续活动状态仍从当前 tasks 读取。
        let taskRootIDs = rootIDs.isEmpty ? [:] : TaskGraph(tasks: tasks).rootIDs
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
            guard rootIDs.contains(taskRootIDs[task.id] ?? task.id), task.activity.phase == .waiting,
                  let tail = tails[task.id], tail.isCaughtUp, let since = tail.reducer.awaitingReplySince else { return nil }
            return (task.id, since)
        })
        // 只缓存已核实的编号和时间；正式输入/新轮次清除问题后同步丢弃旧回执。
        receivedReplies = receivedReplies.filter { _, reply in
            pending[reply.threadID].map { reply.receivedAt >= $0 } ?? false
        }
        if !pending.isEmpty {
            let knownReplies = Array(receivedReplies.values)
            let needsReceipt = pending.filter { id, _ in
                tails[id]?.reducer.activity(acknowledging: knownReplies, for: id, at: now).phase == .waiting
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
                guard var tail = tails[task.id] else { continue }
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
                    failures += 1
                }
            }
        }
        let ids = Set(tasks.map(\.id)); tails = tails.filter { ids.contains($0.key) }
        labels = labels.filter { ids.contains($0.key) }
        return SourceSnapshot(tasks: tasks, quota: quota, warning: failures == 0 ? nil : "\(failures) 个任务的记录不可用，其状态显示为未知。", bytesRead: bytes, observedAt: now)
    }
    /// 按完整原始字段判断复用，父子边仍逐轮覆盖；最多256项、每项原文4KiB，避免缓存长正文。
    private func taskLabels(id: String, title: String, source: String?) -> TaskLabels {
        if let cached = labels[id], cached.rawTitle == title, cached.rawSource == source { return cached }
        let value = TaskLabels(rawTitle: title, rawSource: source, title: Self.cleanTitle(title), parentID: Self.parentFromSource(source))
        if title.utf8.count + (source?.utf8.count ?? 0) <= 4_096, labels[id] != nil || labels.count < 256 {
            labels[id] = value
        } else {
            labels.removeValue(forKey: id)
        }
        return value
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
    private static func cleanTitle(_ title: String) -> String {
        let cleaned = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
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
