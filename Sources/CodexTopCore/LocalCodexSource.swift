import Foundation
import CSQLite

public actor LocalCodexSource {
    public let root: URL
    private var tails: [String: IncrementalRollout] = [:]
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    public func snapshot(now: Date = .now) throws -> SourceSnapshot {
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
        for row in rows {
            guard let id = row["id"], let path = row["rollout_path"] else { continue }
            let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            var task = CodexTask(id: id, title: Self.cleanTitle(row["title"] ?? ""), project: URL(fileURLWithPath: row["cwd"] ?? "").lastPathComponent,
                                 createdAt: Date(timeIntervalSince1970: Double(row["created_at"] ?? "") ?? 0),
                                 updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "") ?? 0),
                                 parentID: parents[id] ?? Self.parentFromSource(row["source"]), rolloutURL: file)
            if !file.path.hasPrefix(root.path + "/") {
                task.activity.detail = "记录位于数据目录之外，未读取"; failures += 1
            } else {
                var tail = tails[id] ?? IncrementalRollout()
                do {
                    bytes += try tail.refresh(url: file)
                    task.activity = tail.reducer.activity.effective(at: now)
                    if let candidate = tail.reducer.quota, quota == nil || candidate.observedAt > quota!.observedAt { quota = candidate }
                    tails[id] = tail
                } catch {
                    task.activity = TaskActivity(detail: "暂时无法读取任务记录")
                    tails.removeValue(forKey: id); failures += 1
                }
            }
            tasks.append(task)
        }
        let ids = Set(tasks.map(\.id)); tails = tails.filter { ids.contains($0.key) }
        return SourceSnapshot(tasks: tasks, quota: quota, warning: failures == 0 ? nil : "\(failures) 个任务的记录不可用，其状态显示为未知。", bytesRead: bytes, observedAt: now)
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
    private func query(_ database: OpaquePointer?, _ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw CodexSourceError.incompatibleDatabase }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw CodexSourceError.databaseUnavailable }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let name = sqlite3_column_name(statement, column), let text = sqlite3_column_text(statement, column) {
                    row[String(cString: name)] = String(cString: text)
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
    private static func parentFromSource(_ source: String?) -> String? {
        guard let data = source?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagent = value["subagent"] as? [String: Any], let spawn = subagent["thread_spawn"] as? [String: Any] else { return nil }
        return spawn["parent_thread_id"] as? String
    }
}

