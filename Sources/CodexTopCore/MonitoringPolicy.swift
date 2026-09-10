import Foundation

public enum PanelTheme: String, Codable, CaseIterable, Sendable {
    case dark, light
}
public enum PanelPlacement: String, Codable, CaseIterable, Sendable {
    case top, floating, orb, menuBar
}

public struct MonitorPreferences: Codable, Equatable, Sendable {
    public var selectedIDs: Set<String> = []
    public var excludedIDs: Set<String> = []
    public var initialized = false
    public var autoMonitor = true
    public var autoEnabledAt = Date()
    public var codexHome: String?
    public var preferredDisplay: String?
    public var floating = false
    public var floatingDisplay: String?
    public var floatingX: Double = 0.72
    public var floatingY: Double = 0.7
    // Optional for compatibility with preferences written before themes were added.
    public var theme: PanelTheme?
    public var placement: PanelPlacement?
    public var uiScale: Double?
    public var resolvedPlacement: PanelPlacement { placement ?? (floating ? .floating : .top) }
    public var resolvedScale: Double {
        guard let uiScale, uiScale.isFinite else { return 1 }
        return min(1, max(0.8, uiScale))
    }
    public init() {}
}

public enum MonitoringPolicy {
    public static func rootID(for id: String, tasks: [CodexTask]) -> String {
        TaskGraph(tasks: tasks).rootIDs[id] ?? id
    }
    public static func roots(in tasks: [CodexTask]) -> [CodexTask] {
        TaskGraph(tasks: tasks).roots
    }
    public static func children(of id: String, tasks: [CodexTask]) -> [CodexTask] {
        TaskGraph(tasks: tasks).children[id] ?? []
    }
    public static func activity(for task: CodexTask, tasks: [CodexTask]) -> TaskActivity {
        let active = children(of: task.id, tasks: tasks).filter { $0.activity.phase.isActive || $0.activity.phase == .failed }
        guard let child = active.min(by: { $0.activity.phase.priority < $1.activity.phase.priority }), child.activity.phase.priority < task.activity.phase.priority else { return task.activity }
        var activity = child.activity
        activity.detail = "子任务 · \(child.activity.detail)"
        return activity
    }
    public static func reconcile(_ preferences: inout MonitorPreferences, tasks: [CodexTask], now: Date) {
        let graph = TaskGraph(tasks: tasks)
        if !preferences.initialized {
            preferences.autoEnabledAt = now
            for t in tasks where t.activity.phase.isActive {
                let root = graph.rootIDs[t.id] ?? t.id
                if !preferences.excludedIDs.contains(root) { preferences.selectedIDs.insert(root) }
            }
            preferences.initialized = true
        }
        guard preferences.autoMonitor else { return }
        for t in tasks where t.createdAt >= preferences.autoEnabledAt && (t.activity.startedAt != nil || t.activity.phase.isActive || t.activity.phase.isFinished || t.activity.phase == .failed) {
            let root = graph.rootIDs[t.id] ?? t.id
            if !preferences.excludedIDs.contains(root) { preferences.selectedIDs.insert(root) }
        }
    }
    public static func applySelection(_ draft: Set<String>, original: Set<String>, preferences: inout MonitorPreferences) {
        let removed = original.subtracting(draft), added = draft.subtracting(original)
        preferences.selectedIDs.subtract(removed)
        preferences.selectedIDs.formUnion(added)
        preferences.excludedIDs.formUnion(removed)
        preferences.excludedIDs.subtract(added)
    }
    public static func selectVisible(_ visible: Set<String>, selected: inout Set<String>) {
        if visible.isSubset(of: selected) { selected.subtract(visible) } else { selected.formUnion(visible) }
    }
}

/// Build once per snapshot rather than rebuilding parent relationships for each row.
public struct TaskGraph: Sendable {
    public let rootIDs: [String: String]
    public let roots: [CodexTask]
    public let children: [String: [CodexTask]]
    public init(tasks: [CodexTask]) {
        let lookup = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [String: String] = [:]
        for task in tasks {
            var current = task.id, path: [String] = [], positions: [String: Int] = [:]
            while resolved[current] == nil, positions[current] == nil, let item = lookup[current] {
                positions[current] = path.count; path.append(current)
                guard let parent = item.parentID, lookup[parent] != nil else { break }
                current = parent
            }
            let root: String
            if let known = resolved[current] { root = known }
            else if let cycleStart = positions[current], path.last != current { root = path[cycleStart...].min() ?? current }
            else { root = current }
            for id in path { resolved[id] = root }
        }
        rootIDs = resolved
        roots = tasks.filter { resolved[$0.id] == $0.id }
        children = Dictionary(grouping: tasks.filter { resolved[$0.id] != $0.id }) { resolved[$0.id] ?? $0.id }
    }
    public func activity(for root: CodexTask) -> TaskActivity {
        guard let child = (children[root.id] ?? []).filter({ $0.activity.phase.isActive || $0.activity.phase == .failed })
            .min(by: { $0.activity.phase.priority < $1.activity.phase.priority }), child.activity.phase.priority < root.activity.phase.priority else { return root.activity }
        var result = child.activity; result.detail = "子任务 · \(result.detail)"; return result
    }
}

public struct PreferencesFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> MonitorPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return MonitorPreferences() }
        return try JSONDecoder().decode(MonitorPreferences.self, from: Data(contentsOf: url))
    }
    public func save(_ preferences: MonitorPreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
