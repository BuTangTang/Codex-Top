import AppKit
import Combine
import SwiftUI
import CodexTopCore

/// 忙碌状态只通知刷新按钮，避免每次后台检查都重新计算整个监控界面。
@MainActor final class TaskRefreshState: ObservableObject {
    @Published fileprivate(set) var isRefreshing = false
}

@MainActor final class TaskStore: ObservableObject {
    @Published private(set) var preferences: MonitorPreferences
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var graph = TaskGraph(tasks: [])
    @Published private(set) var quota: QuotaSnapshot?
    @Published private(set) var quotaRefreshing = false
    @Published private(set) var quotaWarning: String?
    @Published private(set) var sourceWarning: String?
    @Published var notice: String? { didSet { if notice != oldValue { onChange?() } } }
    private(set) var lastRefresh: Date?
    @Published var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused { cancelFastRefresh() }
            updateRolloutWatches()
            if !paused { requestFastRefresh() }
        }
    }
    let refreshState = TaskRefreshState()
    var refreshing: Bool { refreshState.isRefreshing }
    @Published private(set) var loading = true
    @Published private(set) var completionSequence = 0
    /// D-91 刚完成、还没看过的任务：编号 → 完成时间。点开、标为已看或 10 分钟后收进“已结束”。
    @Published private(set) var freshFinished: [String: Date] = [:]
    /// 悬浮球上的绿色个数；打开面板就算看过并清零，面板里的“刚完成”一段不受影响。
    @Published private(set) var unseenFinished: Set<String> = []
    static let freshWindow: TimeInterval = 600
    @Published private(set) var demoPhase: TaskPhase?
    @Published private(set) var systemTheme: PanelTheme = .light
    let demo: Bool
    var onChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var onModeChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onAppearanceWillChange: (() -> Bool)?
    var onExternalNavigation: (() -> Void)?
    private var source: LocalCodexSource
    private var claudeSource: ClaudeCodeSource
    /// 独立状态目录（测试、合成验收）里不读本机真实的 ~/.claude，默认目录改到状态目录下。
    private let defaultClaudeRoot: URL
    /// 压缩记录读取结果缓存，跟设置文件放在同一状态目录。
    private let compressedCacheURL: URL
    /// 数据目录存在才算装了 Claude Code；每轮刷新更新。
    @Published private(set) var claudeInstalled = false
    /// 层 C：Claude Code 设置里有没有 Codex Top 的通知钩子；settings.json 读不懂时为 nil。
    @Published private(set) var claudeHookInstalled: Bool? = false
    private var usageClient: AccountUsageClient
    private var accountQuota: QuotaSnapshot?
    @Published private(set) var historicalQuota: QuotaSnapshot?
    private var usageLoop: Task<Void, Never>?
    private var usageRequest: Task<Void, Never>?
    private var ownedUsageRequests: [UUID: Task<Void, Never>] = [:]
    private var usageRequestID = UUID()
    private var stopping = false
    private let file: PreferencesFile
    private var persistenceAvailable = true
    private var refreshLoop: Task<Void, Never>?
    private var sourceGeneration = 0
    private var rolloutChanges: RolloutChangeMonitor?
    private var fastRefreshTask: Task<Void, Never>?
    private var fastRefreshID: UUID?
    private var fastRefreshNeeded = false
    private var appearanceObservation: NSKeyValueObservation?
    private let stateFolder: URL

    init(stateDirectory: URL? = nil) {
        demo = CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "CodexTopDemo") as? Bool == true
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Top")
        let isolatedState = stateDirectory ?? ProcessInfo.processInfo.environment["CODEX_TOP_STATE_DIR"].map { URL(fileURLWithPath: $0) }
        let stateFolder = isolatedState ?? (demo ? base.appendingPathComponent("Demo") : base)
        self.stateFolder = stateFolder
        defaultClaudeRoot = isolatedState.map { $0.appendingPathComponent("claude", isDirectory: true) } ?? ClaudeCodeSource.defaultRoot
        compressedCacheURL = stateFolder.appendingPathComponent("compressed-status-cache.json")
        file = PreferencesFile(url: stateFolder.appendingPathComponent("preferences.json"))
        var loaded = MonitorPreferences(), failure: String?
        do { loaded = try file.load() } catch { failure = "设置文件无法读取。当前使用默认值，原文件已保留。"; persistenceAvailable = false }
        preferences = loaded
        let root = loaded.codexHome.map { URL(fileURLWithPath: $0) } ?? LocalCodexSource.defaultRoot
        source = LocalCodexSource(root: root, compressedCacheURL: compressedCacheURL)
        claudeSource = ClaudeCodeSource(root: loaded.claudeHome.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultClaudeRoot,
                                        hookEvents: stateFolder.appendingPathComponent("claude-events", isDirectory: true))
        usageClient = AccountUsageClient(root: root)
        notice = failure
        systemTheme = Self.resolvedSystemTheme(NSApplication.shared.effectiveAppearance)
    }
    var rootURL: URL { preferences.codexHome.map { URL(fileURLWithPath: $0) } ?? LocalCodexSource.defaultRoot }
    var claudeRootURL: URL { preferences.claudeHome.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultClaudeRoot }
    /// 面板只看关注的根任务：两种来源都有时才标 CX／CC（D-06）。
    var panelShowsSourceMarks: Bool {
        let selectedIDs = preferences.selectedIDs
        var origins = Set<TaskOrigin>()
        for task in graph.roots where selectedIDs.contains(task.id) { origins.insert(task.origin); if origins.count > 1 { return true } }
        return false
    }
    /// 任务选择器按它列出的全部任务判断。
    var pickerShowsSourceMarks: Bool { Set(graph.roots.map(\.origin)).count > 1 }
    /// 有 Claude Code 任务时额度前写明是 Codex 的（R-22）。
    var hasClaudeTasks: Bool { tasks.contains { $0.origin == .claudeCode } }
    var themeChoice: PanelTheme { preferences.theme ?? .dark }
    /// Rendering always receives a concrete theme; the saved choice may follow macOS.
    var theme: PanelTheme { themeChoice == .system ? systemTheme : themeChoice }
    var placement: PanelPlacement { preferences.resolvedPlacement }
    var orbAppearance: OrbAppearance { preferences.resolvedOrbAppearance }
    var orbPhase: TaskPhase {
        // A source warning can concern an unmonitored history entry. Individual
        // unreadable records already carry .unknown; keep valid attention visible.
        paused || loading || (sourceWarning != nil && tasks.isEmpty) ? .unknown : statusSummary.phase
    }
    var orbStatusLabel: String {
        if paused { return "任务刷新已暂停" }
        if loading { return "正在读取任务状态" }
        if sourceWarning != nil && tasks.isEmpty { return "任务状态暂时无法更新" }
        return orbPhase.label
    }
    /// 关注记录的读取统计只保留诊断数据，不占用监控面板；来源整体失败仍明确提示。
    var panelWarning: String? {
        guard let sourceWarning, !sourceWarning.hasPrefix("关注范围：") else { return nil }
        return sourceWarning
    }
    var uiScale: CGFloat { CGFloat(preferences.resolvedScale) }
    /// 本次计算只取一次图和选择集合，预先计算排序键，保持状态、时间及并列输入顺序。
    var selected: [CodexTask] {
        let graph = self.graph, selectedIDs = preferences.selectedIDs
        var ranked = graph.roots.compactMap { task -> (task: CodexTask, priority: Int)? in
            guard selectedIDs.contains(task.id) else { return nil }
            return (task, graph.activitySource(for: task).activity.phase.priority)
        }
        ranked.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.task.updatedAt > $1.task.updatedAt
        }
        return ranked.map { $0.task }
    }
    var active: [CodexTask] { selected.filter { !graph.activity(for: $0).phase.isFinished } }
    /// “刚完成”一段，最近完成的在前；它们不再出现在“已结束”里。
    var freshTasks: [CodexTask] {
        selected.filter { freshFinished[$0.id] != nil }.sorted { (freshFinished[$0.id] ?? .distantPast) > (freshFinished[$1.id] ?? .distantPast) }
    }
    var finished: [CodexTask] { selected.filter { graph.activity(for: $0).phase.isFinished && freshFinished[$0.id] == nil } }
    func markFinishedSeen(_ id: String) {
        guard freshFinished[id] != nil else { return }
        freshFinished[id] = nil; unseenFinished.remove(id); onChange?()
    }
    func markAllFinishedSeen() {
        guard !freshFinished.isEmpty else { return }
        freshFinished = [:]; unseenFinished = []; onChange?()
    }
    /// 打开面板时调用：悬浮球上的绿色个数清零。
    func acknowledgeFinishedOnOrb() {
        if !unseenFinished.isEmpty { unseenFinished = [] }
    }
    /// 汇总只需已选根任务的阶段，不进行列表排序，也不生成子任务展示文案。
    var statusSummary: MonitorStatusSummary {
        let graph = self.graph, selectedIDs = preferences.selectedIDs
        let phases = graph.roots.compactMap { task -> TaskPhase? in
            guard selectedIDs.contains(task.id) else { return nil }
            return graph.activitySource(for: task).activity.phase
        }
        return MonitorStatusSummary(phases: phases)
    }
    var runningCount: Int { statusSummary.running }
    var attentionCount: Int { statusSummary.attention }
    func start() {
        guard refreshLoop == nil else { return }
        stopping = false
        startObservingAppearance()
        rolloutChanges = RolloutChangeMonitor { [weak self] in self?.requestFastRefresh() }
        updateRolloutWatches()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused { await self.refresh() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        startUsageLoop()
    }
    func startObservingAppearance() {
        updateSystemAppearance(NSApplication.shared.effectiveAppearance)
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.appearanceObservation != nil else { return }
                self.updateSystemAppearance(NSApplication.shared.effectiveAppearance)
            }
        }
    }
    func stop() {
        stopping = true
        appearanceObservation = nil
        cancelFastRefresh()
        rolloutChanges?.stop(); rolloutChanges = nil
        refreshLoop?.cancel(); refreshLoop = nil
        usageLoop?.cancel(); usageLoop = nil
        cancelUsageRequest()
        ownedUsageRequests.values.forEach { $0.cancel() }
    }
    func shutdown() async {
        stop()
        // Requests remain owned while cancellation closes and reaps their CLI,
        // including an old-directory request that is still finishing cleanup.
        let requests = Array(ownedUsageRequests.values)
        for request in requests { await request.value }
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
        guard !demo, !stopping, usageRequest == nil else { return }
        let generation = sourceGeneration, requestID = UUID(), client = usageClient
        usageRequestID = requestID; quotaRefreshing = true
        usageRequest = Task { [weak self] in
            guard let self else { return }
            defer {
                self.ownedUsageRequests.removeValue(forKey: requestID)
                if self.usageRequestID == requestID {
                    self.usageRequest = nil; self.quotaRefreshing = false
                }
            }
            do {
                let snapshot = try await client.snapshot(force: force)
                guard !Task.isCancelled, !self.stopping, generation == self.sourceGeneration,
                      self.usageRequestID == requestID else { return }
                self.accountQuota = snapshot; self.quotaWarning = nil
                self.updateQuota()
            } catch {
                guard !Task.isCancelled, !self.stopping, generation == self.sourceGeneration,
                      self.usageRequestID == requestID else { return }
                // A failed login after switching accounts must not display the
                // previous account or an unrelated conversation's quota as current.
                self.accountQuota = nil; self.updateQuota()
                self.quotaWarning = "账户额度暂时无法更新，请确认所选 Codex 目录的登录与网络；切换账号后可手动刷新。"
            }
        }
        ownedUsageRequests[requestID] = usageRequest
    }
    private func cancelUsageRequest() {
        usageRequestID = UUID(); usageRequest?.cancel(); usageRequest = nil; quotaRefreshing = false
    }
    private func resetUsageSource() {
        cancelUsageRequest()
        usageClient = AccountUsageClient(root: rootURL)
        accountQuota = nil; historicalQuota = nil; quota = nil; quotaWarning = nil
        refreshQuota()
    }
    /// 额度内容没有变化时不重复通知整个监控界面。
    private func updateQuota() {
        let next = demo ? historicalQuota : accountQuota
        if quota != next { quota = next }
    }
    private func updateRolloutWatches() {
        guard !demo, !paused, !stopping else { rolloutChanges?.stop(); return }
        // Watch the waiting activity itself, including a child represented by a
        // selected root. No conversation text is read by the filesystem watcher.
        let urls = Set(tasks.filter {
            $0.activity.phase == .waiting && preferences.selectedIDs.contains(graph.rootIDs[$0.id] ?? $0.id)
        }.map(\.rolloutURL))
        rolloutChanges?.update(urls: urls)
    }
    private func requestFastRefresh() {
        guard !demo, !paused, !stopping else { return }
        fastRefreshNeeded = true
        scheduleFastRefresh()
    }
    private func scheduleFastRefresh() {
        guard fastRefreshNeeded, fastRefreshTask == nil, !refreshing, !paused, !stopping else { return }
        let id = UUID(), generation = sourceGeneration
        fastRefreshID = id
        fastRefreshTask = Task { [weak self] in
            // Coalesce the user message and its adjacent event records into one
            // snapshot; leave the independent account usage cadence unchanged.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.fastRefreshID == id else { return }
            self.fastRefreshTask = nil; self.fastRefreshID = nil
            guard generation == self.sourceGeneration, !self.paused, !self.stopping else { return }
            // A write during another scan remains pending. Its defer schedules
            // a follow-up instead of losing the reply behind the busy guard.
            guard !self.refreshing else { return }
            self.fastRefreshNeeded = false
            await self.refresh()
        }
    }
    private func cancelFastRefresh() {
        fastRefreshTask?.cancel(); fastRefreshTask = nil; fastRefreshID = nil
        fastRefreshNeeded = false
    }
    /// 每轮仍读取状态并执行过期规则，仅在展示内容变化时发布和重排窗口。
    func refresh() async {
        guard !stopping, !refreshing else { return }
        refreshState.isRefreshing = true
        let generation = sourceGeneration
        var needsLayout = loading
        defer {
            refreshState.isRefreshing = false
            if loading { loading = false }
            updateRolloutWatches()
            scheduleFastRefresh()
        }
        do {
            // 完成提示只比较阶段；无需为了布尔判断排序或复制带详情的展示活动。
            let previousRefresh = lastRefresh
            let previousPhases = Dictionary(uniqueKeysWithValues: graph.roots.filter {
                preferences.selectedIDs.contains($0.id)
            }.map { ($0.id, graph.activitySource(for: $0).activity.phase) })
            // 两个来源各自读取；Claude Code 读不到只影响它自己的任务（设计第 6 节）。
            let claudeTasks = await readClaudeTasks()
            guard !stopping, generation == sourceGeneration else { return }
            let codexSnapshot: SourceSnapshot
            do {
                codexSnapshot = demo ? DemoTasks.snapshot(phase: demoPhase) : try await source.snapshot(recoverTimingFor: preferences.selectedIDs, monitoredRootIDs: preferences.selectedIDs)
            } catch {
                guard !stopping, generation == sourceGeneration else { return }
                if sourceWarning != error.localizedDescription { sourceWarning = error.localizedDescription; needsLayout = true }
                // Do not leave the previous snapshot claiming active/completed after source loss.
                let unavailable = tasks.filter { $0.origin == .codex }.map { task in var copy = task; copy.activity = TaskActivity(detail: "数据源不可用，无法确认当前状态"); return copy } + claudeTasks
                if tasks != unavailable { tasks = unavailable; graph = TaskGraph(tasks: tasks); needsLayout = true }
                if needsLayout { onChange?() }
                return
            }
            let snapshot = SourceSnapshot(tasks: codexSnapshot.tasks + claudeTasks, quota: codexSnapshot.quota,
                                          warning: codexSnapshot.warning, observedAt: codexSnapshot.observedAt)
            guard !stopping, generation == sourceGeneration else { return }
            if tasks != snapshot.tasks {
                tasks = snapshot.tasks; graph = TaskGraph(tasks: tasks)
                needsLayout = true
            }
            if historicalQuota != snapshot.quota { historicalQuota = snapshot.quota }
            updateQuota()
            if sourceWarning != snapshot.warning {
                let previousPanelWarning = panelWarning
                sourceWarning = snapshot.warning
                // 隐藏的读取统计不改变面板几何；整体故障提示仍立即重排。
                if previousPanelWarning != panelWarning { needsLayout = true }
            }
            lastRefresh = snapshot.observedAt
            var nextPreferences = preferences
            Self.applyClaudeBaseline(&nextPreferences, claudeTasks: claudeTasks)
            MonitoringPolicy.reconcile(&nextPreferences, tasks: tasks, graph: graph, now: snapshot.observedAt)
            if demo && !preferences.initialized { nextPreferences.selectedIDs = Set(graph.roots.prefix(4).map(\.id)) }
            if preferences != nextPreferences { preferences = nextPreferences; save(); needsLayout = true }
            // 完成时间要在上一轮刷新之后（留 2 分钟余量）才算“刚完成”：启动后压缩记录读完、状态从未知变成
            // 早就完成的，不算（2026-11-09 用户：“连续跳出来两次 14 个任务完成”）。
            let completedAfter = previousRefresh.map { $0.addingTimeInterval(-120) } ?? .distantFuture
            let justCompleted = graph.roots.filter { task in
                guard preferences.selectedIDs.contains(task.id), let old = previousPhases[task.id] else { return false }
                let activity = graph.activitySource(for: task).activity
                return old != .completed && activity.phase == .completed && (activity.lastEventAt ?? .distantPast) >= completedAfter
            }.map(\.id)
            if !justCompleted.isEmpty { completionSequence += 1 }
            var fresh = freshFinished
            for id in justCompleted { fresh[id] = snapshot.observedAt }
            // 取消关注、又开始跑、或完成超过 10 分钟的不再算“刚完成”。
            fresh = fresh.filter { id, at in
                preferences.selectedIDs.contains(id) && snapshot.observedAt.timeIntervalSince(at) < Self.freshWindow &&
                    graph.roots.first(where: { $0.id == id }).map { graph.activitySource(for: $0).activity.phase == .completed } == true
            }
            if fresh != freshFinished { freshFinished = fresh; needsLayout = true }
            let unseen = unseenFinished.union(justCompleted).intersection(fresh.keys)
            if unseen != unseenFinished { unseenFinished = unseen }
        }
        if needsLayout { onChange?() }
    }
    /// 关闭或未安装时没有 Claude Code 任务；演示模式用合成任务，不读本机数据。
    private func readClaudeTasks() async -> [CodexTask] {
        if demo { return DemoTasks.claudeTasks(phase: demoPhase) }
        let installed = await claudeSource.installed
        if claudeInstalled != installed { claudeInstalled = installed }
        guard installed, preferences.resolvedClaudeEnabled else { return [] }
        return await claudeSource.snapshot(keep: preferences.selectedIDs).tasks
    }
    /// 第一次出现 Claude Code 会话时，把已有会话记为基线，避免历史会话一次性涌进关注列表；
    /// 当时正在运行或等待的会话照首次启动的规则加入关注（设计第 6 节）。
    nonisolated static func applyClaudeBaseline(_ preferences: inout MonitorPreferences, claudeTasks: [CodexTask]) {
        guard preferences.claudeBaselineApplied != true, !claudeTasks.isEmpty else { return }
        preferences.claudeBaselineApplied = true
        // 尚未初始化时由首次启动的规则统一处理全部任务。
        guard preferences.initialized else { return }
        preferences.autoBaselineIDs = (preferences.autoBaselineIDs ?? []).union(claudeTasks.map(\.id))
        for task in claudeTasks where task.activity.phase.isActive && !preferences.excludedIDs.contains(task.id) {
            preferences.selectedIDs.insert(task.id)
        }
    }
    func setClaudeEnabled(_ enabled: Bool) {
        guard preferences.resolvedClaudeEnabled != enabled else { return }
        // 关闭时关注设置里的 cc: 编号保留，重新开启后恢复（R-19）。
        preferences.claudeEnabled = enabled; save()
        requestImmediateRefresh()
    }
    func chooseClaudeRoot() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.showsHiddenFiles = true; picker.allowsMultipleSelection = false; picker.directoryURL = claudeRootURL
        picker.message = "选择 Claude Code 数据目录（通常是用户目录下的 .claude）"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        preferences.claudeHome = url.path; save()
        claudeSource = ClaudeCodeSource(root: url, hookEvents: claudeEventsURL)
        refreshClaudeHookStatus()
        requestImmediateRefresh()
    }
    private var claudeEventsURL: URL { stateFolder.appendingPathComponent("claude-events", isDirectory: true) }
    private var claudeHookHelper: URL { stateFolder.appendingPathComponent("bin/codex-top-claude-hook") }
    private var bundledClaudeHook: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codex-top-claude-hook") }
    private var claudeSettingsURL: URL { claudeRootURL.appendingPathComponent("settings.json") }

    /// 状态只从 settings.json 读回来，不另存开关。装着的话顺手把小程序换成这一版自带的。
    func refreshClaudeHookStatus() {
        claudeHookInstalled = ClaudeHookInstaller.isInstalled(settings: claudeSettingsURL, helper: claudeHookHelper)
        if claudeHookInstalled == true, let bundled = try? Data(contentsOf: bundledClaudeHook),
           (try? Data(contentsOf: claudeHookHelper)) != bundled { try? copyClaudeHook() }
    }

    /// 打开：复制小程序、在 Claude Code 设置里加自己那一条；关闭：删掉那一条、小程序和记下的事件。
    func setClaudeHook(_ enabled: Bool) {
        let backups = stateFolder.appendingPathComponent("claude-settings-backups", isDirectory: true)
        do {
            if enabled {
                try copyClaudeHook()
                try ClaudeHookInstaller.install(settings: claudeSettingsURL, helper: claudeHookHelper, backups: backups)
            } else {
                try ClaudeHookInstaller.remove(settings: claudeSettingsURL, helper: claudeHookHelper, backups: backups)
                try? FileManager.default.removeItem(at: claudeHookHelper)
                try? FileManager.default.removeItem(at: claudeEventsURL)
            }
            notice = nil
        } catch ClaudeHookInstaller.Failure.invalidJSON {
            notice = "Claude Code 的 settings.json 不是标准 JSON，没有改动。"
        } catch ClaudeHookInstaller.Failure.changedWhileEditing {
            notice = "settings.json 刚被别的程序改过，没有改动，请再试一次。"
        } catch {
            notice = enabled ? "没能加上 Claude Code 钩子，设置文件没有改动。" : "没能移除 Claude Code 钩子。"
        }
        refreshClaudeHookStatus()
        requestImmediateRefresh()
    }

    private func copyClaudeHook() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: claudeHookHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: claudeHookHelper)
        try fm.copyItem(at: bundledClaudeHook, to: claudeHookHelper)
    }

    private func requestImmediateRefresh() {
        onChange?()
        Task { await refresh() }
    }
    func previewDemoPhase(_ phase: TaskPhase?) {
        guard demo else { return }
        demoPhase = phase
        if phase != nil { setPlacement(.orb) }
        Task { await refresh() }
    }
    func applySelection(_ draft: Set<String>, original: Set<String>) {
        MonitoringPolicy.applySelection(draft, original: original, preferences: &preferences); save(); onChange?()
        updateRolloutWatches()
    }
    func removeFromMonitoring(_ id: String) {
        let root = graph.rootIDs[id] ?? id
        guard preferences.selectedIDs.contains(root) else { return }
        applySelection([], original: [root])
    }
    func setAutoMonitor(_ enabled: Bool) {
        MonitoringPolicy.setAutoMonitor(enabled, preferences: &preferences, tasks: tasks, now: .now)
        save(); updateRolloutWatches()
    }
    func setFloating(_ enabled: Bool) { setPlacement(enabled ? .floating : preferences.resolvedUnpinnedPlacement) }
    func setPlacement(_ value: PanelPlacement) {
        guard placement != value else { return }
        preferences.setPlacement(value)
        save(); onModeChange?()
    }
    func setScale(_ value: Double) { preferences.uiScale = MonitorScale.renderingScale(for: value); save(); onChange?() }
    func setOrbAppearance(_ value: OrbAppearance) {
        guard orbAppearance != value else { return }
        preferences.orbAppearance = value
        save()
    }
    func setVisibleTaskCount(_ value: Int) {
        preferences.visibleTaskCount = value
        preferences.visibleTaskCount = preferences.resolvedVisibleTaskCount
        save(); onChange?()
    }
    func setFinishedRetentionDays(_ value: Int) {
        preferences.finishedRetentionDays = value
        preferences.finishedRetentionDays = preferences.resolvedFinishedRetentionDays
        MonitoringPolicy.reconcile(&preferences, tasks: tasks, now: .now)
        save(); updateRolloutWatches(); onChange?()
    }
    func setTheme(_ theme: PanelTheme) {
        guard themeChoice != theme else { return }
        let resolved = theme == .system ? systemTheme : theme
        if self.theme == resolved { preferences.theme = theme }
        else { changeTheme { preferences.theme = theme } }
        save(); onAppearanceChange?()
    }
    static func resolvedSystemTheme(_ appearance: NSAppearance) -> PanelTheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
    func updateSystemAppearance(_ appearance: NSAppearance) {
        let next = Self.resolvedSystemTheme(appearance)
        guard systemTheme != next else { return }
        if themeChoice == .system {
            changeTheme { systemTheme = next }
            onAppearanceChange?()
        } else { systemTheme = next }
    }
    private func changeTheme(_ update: () -> Void) {
        if onAppearanceWillChange?() == true {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else {
            withAnimation(ThemeMotion.transition(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), update)
        }
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
            cancelFastRefresh(); rolloutChanges?.stop()
            preferences.codexHome = url.path; preferences.initialized = false
            preferences.selectedIDs.removeAll(); preferences.excludedIDs.removeAll()
            preferences.automaticallyRemovedIDs = []; preferences.retentionProtectedIDs = []
            source = LocalCodexSource(root: url, compressedCacheURL: compressedCacheURL); tasks = []; graph = TaskGraph(tasks: []); quota = nil
            resetUsageSource()
            sourceWarning = nil; loading = true; save(); onChange?()
            Task { await refresh() }
        }
    }
    func openTask(_ task: CodexTask) {
        markFinishedSeen(task.id)
        if demo { notice = "这是演示任务。实际任务会在 \(task.origin.displayName) 中打开。"; return }
        let target = graph.navigationTarget(for: task)
        if target.origin == .claudeCode { openClaudeTask(target); return }
        guard let link = target.deepLink,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            taskNavigationFailed(id: target.id); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // LaunchServices calls this on its own queue. Explicit Sendable prevents
        // inheriting TaskStore's MainActor isolation before the hop below.
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { @Sendable [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil { self.taskNavigationFailed(id: target.id) }
                else { self.onExternalNavigation?() }
            }
        }
    }
    /// 桌面 App 的会话直达；其他入口复制会话编号，桌面 App 打不开时说明，不假装成功（R-17、D-07、D-85）。
    private func openClaudeTask(_ task: CodexTask) {
        let sessionID = task.claudeSessionID ?? task.id
        guard let link = task.deepLink,
              let app = NSWorkspace.shared.urlForApplication(toOpen: link) else {
            copyClaudeSession(sessionID, desktop: task.claudeLaunch?.fromDesktopApp == true); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { @Sendable [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil { self.copyClaudeSession(sessionID, desktop: true) }
                else { self.onExternalNavigation?() }
            }
        }
    }
    private func copyClaudeSession(_ sessionID: String, desktop: Bool) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sessionID, forType: .string)
        // D-85：终端或 IDE 里的会话只静默复制编号，不再弹提示；桌面 App 打不开仍说明。
        if desktop { notice = "无法打开 Claude，会话编号已复制。请确认已安装 Claude 桌面 App。" }
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
            cancelFastRefresh(); rolloutChanges?.stop()
            source = LocalCodexSource(root: LocalCodexSource.defaultRoot, compressedCacheURL: compressedCacheURL); claudeSource = ClaudeCodeSource(root: defaultClaudeRoot, hookEvents: claudeEventsURL)
            refreshClaudeHookStatus()
            onDisplayChange?(); onModeChange?(); onAppearanceChange?()
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
            let resolvedPhase = phase ?? spec.2
            task.activity = TaskActivity(phase: resolvedPhase, detail: phase?.label ?? spec.3, lastEventAt: .now,
                                         startedAt: started.addingTimeInterval(-204 + Double(index * 40)),
                                         waitingStartedAt: resolvedPhase == .waiting ? started : nil)
            return task
        }
        return SourceSnapshot(tasks: tasks)
    }
    /// 两条合成的 Claude Code 任务（一条运行、一条等待），用于验收来源标记；不读本机数据。
    static func claudeTasks(phase: TaskPhase? = nil) -> [CodexTask] {
        [("重构登录模块", "web-app", TaskPhase.running, "正在处理任务"), ("补充单元测试", "web-app", .waiting, "等待你的回答")]
            .enumerated().map { index, spec in
                var task = CodexTask(id: "cc:00000000-0000-4000-9000-00000000000\(index)", title: spec.0, project: spec.1,
                                     createdAt: started.addingTimeInterval(-500), updatedAt: started.addingTimeInterval(-Double(index) - 0.5),
                                     rolloutURL: URL(fileURLWithPath: "/demo/claude.jsonl"), origin: .claudeCode)
                let resolvedPhase = phase ?? spec.2
                task.activity = TaskActivity(phase: resolvedPhase, detail: phase?.label ?? spec.3, lastEventAt: .now,
                                             startedAt: started.addingTimeInterval(-150 + Double(index * 30)),
                                             waitingStartedAt: resolvedPhase == .waiting ? started : nil)
                return task
            }
    }
}
