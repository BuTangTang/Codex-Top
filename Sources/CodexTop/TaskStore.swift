import AppKit
import Combine
import SwiftUI
import CodexTopCore

@MainActor final class TaskStore: ObservableObject {
    @Published private(set) var preferences: MonitorPreferences
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var graph = TaskGraph(tasks: [])
    @Published private(set) var quota: QuotaSnapshot?
    @Published private(set) var quotaRefreshing = false
    @Published private(set) var quotaWarning: String?
    @Published private(set) var sourceWarning: String?
    @Published var notice: String? { didSet { if notice != oldValue { onChange?() } } }
    @Published var dockingHint = false
    @Published private(set) var lastRefresh: Date?
    @Published var paused = false
    @Published private(set) var refreshing = false
    @Published private(set) var loading = true
    @Published private(set) var completionSequence = 0
    @Published private(set) var demoPhase: TaskPhase?
    let demo: Bool
    var onChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var onModeChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onAppearanceWillChange: (() -> Bool)?
    var onExternalNavigation: (() -> Void)?
    private var source: LocalCodexSource
    private var usageClient: AccountUsageClient
    private var accountQuota: QuotaSnapshot?
    private var logQuota: QuotaSnapshot?
    private var usageLoop: Task<Void, Never>?
    private var usageRequest: Task<Void, Never>?
    private var usageRequestID = UUID()
    private let file: PreferencesFile
    private var persistenceAvailable = true
    private var refreshLoop: Task<Void, Never>?
    private var sourceGeneration = 0

    init() {
        demo = CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "CodexTopDemo") as? Bool == true
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Top")
        let stateFolder = ProcessInfo.processInfo.environment["CODEX_TOP_STATE_DIR"].map { URL(fileURLWithPath: $0) } ?? (demo ? base.appendingPathComponent("Demo") : base)
        file = PreferencesFile(url: stateFolder.appendingPathComponent("preferences.json"))
        var loaded = MonitorPreferences(), failure: String?
        do { loaded = try file.load() } catch { failure = "设置文件无法读取。当前使用默认值，原文件已保留。"; persistenceAvailable = false }
        preferences = loaded
        let root = loaded.codexHome.map { URL(fileURLWithPath: $0) } ?? LocalCodexSource.defaultRoot
        source = LocalCodexSource(root: root)
        usageClient = AccountUsageClient(root: root)
        notice = failure
    }
    var rootURL: URL { preferences.codexHome.map { URL(fileURLWithPath: $0) } ?? LocalCodexSource.defaultRoot }
    var theme: PanelTheme { preferences.theme ?? .dark }
    var placement: PanelPlacement { preferences.resolvedPlacement }
    var uiScale: CGFloat { CGFloat(preferences.resolvedScale) }
    var selected: [CodexTask] {
        graph.roots.filter { preferences.selectedIDs.contains($0.id) }.sorted {
            let left = graph.activity(for: $0), right = graph.activity(for: $1)
            if left.phase.priority != right.phase.priority { return left.phase.priority < right.phase.priority }
            return $0.updatedAt > $1.updatedAt
        }
    }
    var active: [CodexTask] { selected.filter { !graph.activity(for: $0).phase.isFinished } }
    var finished: [CodexTask] { selected.filter { graph.activity(for: $0).phase.isFinished } }
    var statusSummary: MonitorStatusSummary { MonitorStatusSummary(phases: selected.map { graph.activity(for: $0).phase }) }
    var runningCount: Int { statusSummary.running }
    var attentionCount: Int { statusSummary.attention }
    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused { await self.refresh() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        startUsageLoop()
    }
    func stop() {
        refreshLoop?.cancel(); refreshLoop = nil
        usageLoop?.cancel(); usageLoop = nil
        cancelUsageRequest()
    }
    private func startUsageLoop() {
        guard !demo, usageLoop == nil else { return }
        usageLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshQuota()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
    func refreshQuota(force: Bool = false) {
        guard !demo, usageRequest == nil, force || !paused else { return }
        let generation = sourceGeneration, requestID = UUID(), client = usageClient
        usageRequestID = requestID; quotaRefreshing = true
        usageRequest = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.usageRequestID == requestID {
                    self.usageRequest = nil; self.quotaRefreshing = false
                }
            }
            do {
                let snapshot = try await client.snapshot(force: force)
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                self.accountQuota = snapshot; self.quotaWarning = nil
                self.updateQuota()
            } catch {
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                self.quotaWarning = "账户额度暂时无法更新，可打开官方用量页面查看。"
            }
        }
    }
    private func cancelUsageRequest() {
        usageRequestID = UUID(); usageRequest?.cancel(); usageRequest = nil; quotaRefreshing = false
    }
    private func resetUsageSource() {
        cancelUsageRequest()
        usageClient = AccountUsageClient(root: rootURL)
        accountQuota = nil; logQuota = nil; quota = nil; quotaWarning = nil
        refreshQuota()
    }
    private func updateQuota() {
        quota = [accountQuota, logQuota].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let generation = sourceGeneration
        defer { refreshing = false; loading = false }
        do {
            let previousPhases = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, graph.activity(for: $0).phase) })
            let snapshot = demo ? DemoTasks.snapshot(phase: demoPhase) : try await source.snapshot()
            guard generation == sourceGeneration else { return }
            tasks = snapshot.tasks; graph = TaskGraph(tasks: tasks)
            logQuota = snapshot.quota; updateQuota()
            sourceWarning = snapshot.warning; lastRefresh = snapshot.observedAt
            let previous = preferences
            MonitoringPolicy.reconcile(&preferences, tasks: tasks, now: snapshot.observedAt)
            if demo && !previous.initialized { preferences.selectedIDs = Set(graph.roots.prefix(4).map(\.id)) }
            if preferences != previous { save() }
            if selected.contains(where: { task in
                guard let old = previousPhases[task.id] else { return false }
                return old != .completed && graph.activity(for: task).phase == .completed
            }) { completionSequence += 1 }
        } catch {
            guard generation == sourceGeneration else { return }
            sourceWarning = error.localizedDescription
            // Do not leave the previous snapshot claiming active/completed after source loss.
            tasks = tasks.map { task in var copy = task; copy.activity = TaskActivity(detail: "数据源不可用，无法确认当前状态"); return copy }
            graph = TaskGraph(tasks: tasks)
        }
        onChange?()
    }
    func previewDemoPhase(_ phase: TaskPhase?) {
        guard demo else { return }
        demoPhase = phase
        if phase != nil { setPlacement(.orb) }
        Task { await refresh() }
    }
    func applySelection(_ draft: Set<String>, original: Set<String>) {
        MonitoringPolicy.applySelection(draft, original: original, preferences: &preferences); save(); onChange?()
    }
    func setAutoMonitor(_ enabled: Bool) {
        MonitoringPolicy.setAutoMonitor(enabled, preferences: &preferences, tasks: tasks, now: .now)
        save()
    }
    func setFloating(_ enabled: Bool) { setPlacement(enabled ? .floating : .top) }
    func setPlacement(_ value: PanelPlacement) {
        preferences.placement = value; preferences.floating = value == .floating
        save(); onModeChange?()
    }
    func dockToMenuBar(display: String) {
        preferences.preferredDisplay = display
        preferences.placement = .menuBar; preferences.floating = false
        save(); onModeChange?()
    }
    func setScale(_ value: Double) { preferences.uiScale = min(1, max(0.8, value)); save(); onChange?() }
    func setTheme(_ theme: PanelTheme) {
        guard self.theme != theme else { return }
        if onAppearanceWillChange?() == true {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { preferences.theme = theme }
        } else {
            withAnimation(ThemeMotion.transition(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                preferences.theme = theme
            }
        }
        save(); onAppearanceChange?()
    }
    func setDisplay(_ id: String) { preferences.preferredDisplay = id.isEmpty ? nil : id; save(); onDisplayChange?() }
    func saveFloatingPosition(display: String, x: Double, y: Double) {
        preferences.floatingDisplay = display; preferences.floatingX = x; preferences.floatingY = y; save()
    }
    func chooseRoot() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.showsHiddenFiles = true; picker.allowsMultipleSelection = false; picker.directoryURL = rootURL
        picker.message = "选择 Codex 数据目录（通常是用户目录下的 .codex）"
        if picker.runModal() == .OK, let url = picker.url {
            sourceGeneration += 1
            preferences.codexHome = url.path; preferences.initialized = false
            preferences.selectedIDs.removeAll(); preferences.excludedIDs.removeAll()
            source = LocalCodexSource(root: url); tasks = []; graph = TaskGraph(tasks: []); quota = nil
            resetUsageSource()
            sourceWarning = nil; loading = true; save(); onChange?()
            Task { await refresh() }
        }
    }
    func openTask(_ task: CodexTask) {
        if demo { notice = "这是演示任务。实际任务会在 Codex 中打开。"; return }
        guard let link = task.deepLink,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            taskNavigationFailed(id: task.id); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // LaunchServices calls this on its own queue. Explicit Sendable prevents
        // inheriting TaskStore's MainActor isolation before the hop below.
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { @Sendable [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil { self.taskNavigationFailed(id: task.id) }
                else { self.onExternalNavigation?() }
            }
        }
    }
    private func taskNavigationFailed(id: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
        notice = "无法打开 Codex，任务 ID 已复制。请确认已安装 Codex。"
    }
    func openUsagePage() {
        // The desktop deep-link whitelist does not currently include settings/usage.
        // This is the official usage destination referenced by the Codex app itself.
        let url = URL(string: "https://chatgpt.com/codex/settings/usage")!
        if NSWorkspace.shared.open(url) { onExternalNavigation?() }
        else { notice = "无法打开用量页面，请在浏览器中访问 chatgpt.com/codex/settings/usage。" }
    }
    func restorePreferences() {
        do {
            if FileManager.default.fileExists(atPath: file.url.path) {
                let backup = file.url.deletingLastPathComponent().appendingPathComponent("preferences-backup-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: file.url, to: backup)
            }
            preferences = MonitorPreferences(); persistenceAvailable = true; notice = nil; save()
            sourceGeneration += 1; tasks = []; graph = TaskGraph(tasks: []); quota = nil; sourceWarning = nil; loading = true
            source = LocalCodexSource(root: LocalCodexSource.defaultRoot); onDisplayChange?(); onModeChange?(); onAppearanceChange?()
            resetUsageSource()
            Task { await refresh() }
        } catch { notice = "无法备份原设置，尚未重置。" }
    }
    private func save() {
        guard persistenceAvailable else { return }
        do { try file.save(preferences) } catch { notice = "设置保存失败，请检查应用数据目录的权限。" }
    }
}

enum DemoTasks {
    static let started = Date()
    static func snapshot(phase: TaskPhase? = nil) -> SourceSnapshot {
        let specifications: [(String, String, TaskPhase, String)] = [
            ("审核代码改动", "桌面工具", .waiting, "等待你确认"),
            ("整理项目文件", "文件管理", .running, "正在扫描项目文件"),
            ("检查界面布局", "桌面工具", .running, "正在检查窗口与外接屏"),
            ("生成使用说明", "文档整理", .completed, "本轮执行已结束"),
            ("导出文件清单", "文件管理", .idle, "等待开始"),
            ("修复路径识别", "文件管理", .unknown, "较久未收到新活动")
        ]
        let tasks = specifications.enumerated().map { index, spec in
            var task = CodexTask(id: "00000000-0000-4000-8000-00000000000\(index)", title: spec.0, project: spec.1,
                                 createdAt: started.addingTimeInterval(-600), updatedAt: started.addingTimeInterval(-Double(index)),
                                 rolloutURL: URL(fileURLWithPath: "/demo/rollout.jsonl"))
            task.activity = TaskActivity(phase: phase ?? spec.2, detail: phase?.label ?? spec.3, lastEventAt: .now, startedAt: started.addingTimeInterval(-204 + Double(index * 40)))
            return task
        }
        return SourceSnapshot(tasks: tasks)
    }
}
