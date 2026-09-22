import Foundation

public enum PanelTheme: String, Codable, CaseIterable, Sendable {
    case dark, light, system
}
public enum PanelPlacement: String, Codable, CaseIterable, Sendable {
    case top, floating, orb, menuBar
}
public enum OrbAppearance: String, Codable, CaseIterable, Sendable {
    case ring, twinArc

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Preserve the rest of the preferences when replacing the retired prototype.
        self = value == "robot" ? .twinArc : Self(rawValue: value) ?? .ring
    }
}

public struct MonitorPreferences: Codable, Equatable, Sendable {
    public var selectedIDs: Set<String> = []
    public var excludedIDs: Set<String> = []
    public var initialized = false
    public var autoMonitor = true
    public var autoEnabledAt = Date()
    // Optional so older preferences can establish a conservative baseline on refresh.
    public var autoBaselineIDs: Set<String>?
    public var codexHome: String?
    public var preferredDisplay: String?
    public var floating = false
    public var floatingDisplay: String?
    public var floatingX: Double = 0.72
    public var floatingY: Double = 0.7
    // Optional for compatibility with preferences written before themes were added.
    public var theme: PanelTheme?
    // Missing in older preferences: keep the original ring until explicitly changed.
    public var orbAppearance: OrbAppearance?
    public var placement: PanelPlacement?
    public var floatingReturnPlacement: PanelPlacement?
    // Persist the rendering factor so legacy 0.75 retains its exact size.
    public var uiScale: Double?
    public var visibleTaskCount: Int?
    // Keep automatic retirement separate from the user's explicit exclusions.
    public var finishedRetentionDays: Int?
    public var automaticallyRemovedIDs: Set<String>?
    public var retentionProtectedIDs: Set<String>?
    // Local filing decisions store only round metadata, never titles or message content.
    public var manuallyFinishedTasks: [String: FinishedTaskRecord]?
    public static let finishedRetentionOptions = [0, 3, 7, 14, 30]
    public var resolvedFinishedRetentionDays: Int {
        let days = finishedRetentionDays ?? 7
        return Self.finishedRetentionOptions.contains(days) ? days : 7
    }
    public static let visibleTaskCountRange = 1...12
    public var resolvedVisibleTaskCount: Int {
        min(Self.visibleTaskCountRange.upperBound, max(Self.visibleTaskCountRange.lowerBound, visibleTaskCount ?? 4))
    }
    public var resolvedPlacement: PanelPlacement { placement ?? (floating ? .floating : .top) }
    public var resolvedOrbAppearance: OrbAppearance { orbAppearance ?? .ring }
    public var resolvedUnpinnedPlacement: PanelPlacement {
        guard let previous = floatingReturnPlacement, previous != .floating else { return .top }
        return previous
    }
    public var resolvedScale: Double {
        MonitorScale.renderingScale(for: resolvedDisplayScale)
    }
    public var resolvedDisplayScale: Double {
        MonitorScale.displayScale(forRenderingScale: uiScale ?? MonitorScale.baseline)
    }
    public init() {}
    public mutating func setPlacement(_ value: PanelPlacement) {
        if value == .floating && resolvedPlacement != .floating {
            floatingReturnPlacement = resolvedPlacement
        }
        placement = value
        floating = value == .floating
    }
}

public struct FinishedTaskRecord: Codable, Equatable, Sendable {
    public struct Round: Codable, Equatable, Sendable {
        var turnID: String?
        var startedAt: Date?
        var finishedAt: Date?
    }
    var recordedAt: Date
    var rounds: [String: Round]
}

public enum MonitoringPolicy {
    public static func canFinish(_ root: CodexTask, graph: TaskGraph) -> Bool {
        graph.activity(for: root).phase.isFinished && ([root] + (graph.children[root.id] ?? [])).allSatisfy {
            $0.activity.phase.isFinished || $0.activity.phase == .idle
        }
    }
    public static func isManuallyFinished(_ root: CodexTask, preferences: MonitorPreferences, graph: TaskGraph) -> Bool {
        preferences.manuallyFinishedTasks?[root.id] != nil && canFinish(root, graph: graph)
    }
    public static func finish(_ root: CodexTask, preferences: inout MonitorPreferences, graph: TaskGraph, now: Date) {
        guard preferences.selectedIDs.contains(root.id), canFinish(root, graph: graph) else { return }
        let members = [root] + (graph.children[root.id] ?? [])
        let rounds = Dictionary(uniqueKeysWithValues: members.map { task in
            (task.id, FinishedTaskRecord.Round(turnID: task.activity.turnID,
                startedAt: task.activity.startedAt, finishedAt: task.activity.finishedAt))
        })
        if preferences.manuallyFinishedTasks == nil { preferences.manuallyFinishedTasks = [:] }
        preferences.manuallyFinishedTasks?[root.id] = FinishedTaskRecord(recordedAt: now, rounds: rounds)
    }
    private static func reconcileFinished(_ preferences: inout MonitorPreferences, graph: TaskGraph) {
        guard var records = preferences.manuallyFinishedTasks else { return }
        let monitored = preferences.selectedIDs.union(preferences.automaticallyRemovedIDs ?? [])
        records = records.filter { monitored.contains($0.key) && !preferences.excludedIDs.contains($0.key) }
        for root in graph.roots {
            guard let record = records[root.id] else { continue }
            let resumed = ([root] + (graph.children[root.id] ?? [])).contains { task in
                let current = task.activity, previous = record.rounds[task.id]
                if current.phase.isActive || current.phase == .failed { return true }
                if let turn = current.turnID, let old = previous?.turnID, turn != old { return true }
                // Explicit starts/ends also catch an entire new round between scans or restarts.
                // Database timestamps, trailing usage events and file mtime are not evidence.
                var dates = [(current.startedAt, previous?.startedAt)]
                if current.turnID == nil || previous?.turnID == nil { dates.append((current.finishedAt, previous?.finishedAt)) }
                for (date, old) in dates {
                    if let date, date.timeIntervalSince1970.isFinite, date > (old ?? record.recordedAt) { return true }
                }
                return false
            }
            if resumed {
                records.removeValue(forKey: root.id)
                if preferences.automaticallyRemovedIDs?.remove(root.id) != nil,
                   !preferences.excludedIDs.contains(root.id) { preferences.selectedIDs.insert(root.id) }
            }
        }
        preferences.manuallyFinishedTasks = records
    }
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
            preferences.autoBaselineIDs = Set(tasks.map(\.id))
            for t in tasks where t.activity.phase.isActive {
                let root = graph.rootIDs[t.id] ?? t.id
                if !preferences.excludedIDs.contains(root) { preferences.selectedIDs.insert(root) }
            }
            preferences.initialized = true
        }
        if preferences.autoBaselineIDs == nil {
            // Keep legacy catch-up for later tasks, without guessing which same-second IDs were new.
            preferences.autoBaselineIDs = Set(tasks.filter { $0.createdAt < preferences.autoEnabledAt }.map(\.id))
        }
        if preferences.autoMonitor {
            // SQLite creation timestamps have whole-second precision; Date() does not.
            let creationBoundary = Date(timeIntervalSince1970: floor(preferences.autoEnabledAt.timeIntervalSince1970))
            for t in tasks where t.createdAt >= creationBoundary && preferences.autoBaselineIDs?.contains(t.id) != true && (t.activity.startedAt != nil || t.activity.phase.isActive || t.activity.phase.isFinished || t.activity.phase == .failed) {
                let root = graph.rootIDs[t.id] ?? t.id
                if !preferences.excludedIDs.contains(root), preferences.automaticallyRemovedIDs?.contains(root) != true {
                    preferences.selectedIDs.insert(root)
                }
            }
        }
        reconcileFinished(&preferences, graph: graph)
        applyRetention(&preferences, graph: graph, now: now)
    }
    private static func applyRetention(_ preferences: inout MonitorPreferences, graph: TaskGraph, now: Date) {
        var retired = preferences.automaticallyRemovedIDs ?? []
        retired.subtract(preferences.excludedIDs)
        let days = preferences.resolvedFinishedRetentionDays
        guard days > 0 else {
            preferences.selectedIDs.formUnion(retired)
            preferences.automaticallyRemovedIDs = []
            return
        }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for root in graph.roots where preferences.selectedIDs.contains(root.id) || retired.contains(root.id) {
            let phase = graph.activity(for: root).phase
            // An explicit resumed state is sufficient even if its clock is missing.
            if retired.contains(root.id), phase.isActive || phase == .failed {
                retired.remove(root.id)
                if !preferences.excludedIDs.contains(root.id) { preferences.selectedIDs.insert(root.id) }
                continue
            }
            let members = [root] + (graph.children[root.id] ?? [])
            // Use real activity/database update timestamps, never task creation or file mtime.
            // A missing/unknown member is not evidence that the whole conversation ended.
            let dates = members.map { [$0.updatedAt, $0.activity.lastEventAt].compactMap { $0 } }
            guard dates.joined().allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { continue }
            // The source represents an absent DB timestamp as epoch zero. Every
            // member needs a usable date; an old sibling cannot stand in for it.
            let latestPerMember = dates.compactMap { $0.filter { $0.timeIntervalSince1970 > 0 }.max() }
            guard latestPerMember.count == members.count, let latest = latestPerMember.max() else { continue }
            let expired = members.allSatisfy { $0.activity.phase.isFinished } && latest <= cutoff
            if retired.contains(root.id) {
                if phase.isFinished && latest > cutoff {
                    retired.remove(root.id)
                    if !preferences.excludedIDs.contains(root.id) { preferences.selectedIDs.insert(root.id) }
                }
            } else if expired && preferences.manuallyFinishedTasks?[root.id] != nil && preferences.retentionProtectedIDs?.contains(root.id) != true {
                preferences.selectedIDs.remove(root.id)
                retired.insert(root.id)
            }
        }
        preferences.automaticallyRemovedIDs = retired
    }
    public static func setAutoMonitor(_ enabled: Bool, preferences: inout MonitorPreferences, tasks: [CodexTask], now: Date) {
        preferences.autoMonitor = enabled
        if enabled {
            preferences.autoEnabledAt = now
            preferences.autoBaselineIDs = Set(tasks.map(\.id))
        }
    }
    public static func applySelection(_ draft: Set<String>, original: Set<String>, preferences: inout MonitorPreferences) {
        let removed = original.subtracting(draft), added = draft.subtracting(original)
        preferences.selectedIDs.subtract(removed)
        preferences.selectedIDs.formUnion(added)
        preferences.excludedIDs.formUnion(removed)
        preferences.excludedIDs.subtract(added)
        var protected = preferences.retentionProtectedIDs ?? []
        protected.formUnion(added)
        protected.subtract(removed)
        preferences.retentionProtectedIDs = protected
        preferences.automaticallyRemovedIDs?.subtract(added.union(removed))
        for id in added.union(removed) { preferences.manuallyFinishedTasks?.removeValue(forKey: id) }
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
        let source = activitySource(for: root)
        guard source.id != root.id else { return root.activity }
        var result = source.activity; result.detail = "子任务 · \(result.detail)"; return result
    }
    public func activitySource(for root: CodexTask) -> CodexTask {
        guard let child = (children[root.id] ?? []).filter({ $0.activity.phase.isActive || $0.activity.phase == .failed })
            .min(by: { $0.activity.phase.priority < $1.activity.phase.priority }), child.activity.phase.priority < root.activity.phase.priority else { return root }
        return child
    }
    /// A pending row opens the task that actually supplied its question or approval.
    /// Other rows keep their existing root-task destination.
    public func navigationTarget(for root: CodexTask) -> CodexTask {
        let source = activitySource(for: root)
        return source.activity.phase == .waiting ? source : root
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
