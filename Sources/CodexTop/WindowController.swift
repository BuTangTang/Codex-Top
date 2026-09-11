import AppKit
import SwiftUI
import Combine
import CodexTopCore

struct DisplayChoice: Identifiable {
    let id: String
    let name: String
    let screen: NSScreen
    var notchHeight: CGFloat { screen.safeAreaInsets.top }
    var notchWidth: CGFloat {
        guard notchHeight > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, right.minX - left.maxX)
    }
    static func available() -> [DisplayChoice] {
        NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let id: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(), let string = CFUUIDCreateString(nil, uuid) { id = string as String }
            else { id = String(number) }
            return DisplayChoice(id: id, name: screen.localizedName + (CGDisplayIsBuiltin(number) != 0 ? " · 内置" : " · 外接"), screen: screen)
        }
    }
    var isPrimary: Bool {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
    }
}

final class UtilityPanel: NSPanel {
    var acceptsKeyboard = false
    var escapeAction: (() -> Void)?
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.24 }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, let escapeAction { escapeAction(); return true }
        // A nonactivating panel can own keyboard focus while another app stays active.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if isKeyWindow, modifiers == .command,
           let key = event.charactersIgnoringModifiers, ["+", "=", "-"].contains(key),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// Always-active AppKit tracking also receives hover while another application is key.
// The small top panel must never need a click merely to activate SwiftUI tracking.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var hoverChanged: (Bool) -> Void = { _ in }
    var contextMenuProvider: () -> NSMenu? = { nil }
    private var hoverArea: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged(false) }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        else { super.rightMouseDown(with: event) }
    }
}

@MainActor final class WindowController: NSObject, NSWindowDelegate {
    let store: TaskStore
    var orbContextMenu: NSMenu?
    var statusAnchorProvider: (() -> CGRect?)?
    private let top = UtilityPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let floating = UtilityPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var picker: NSWindow?
    private var settings: NSWindow?
    private var observer: NSObjectProtocol?
    private var hideTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var topMotion: Task<Void, Never>?
    private var topTarget = CGRect.zero
    private var topExpanded = false
    private let topState = TopPanelState()
    private var floatingDismissTask: Task<Void, Never>?
    private let floatingPresentation = PanelPresentation()
    private var savePositionTask: Task<Void, Never>?
    private var positioning = false
    private var topHovered = false
    private let orbState = OrbMorphState()
    private var orbAnchor = CGRect.zero
    private var orbExpandedFrame: CGRect?
    private var orbExpansionDirection: OrbExpansionDirection?
    private var orbCanvas: CGRect?
    private var orbMotion: Int?
    private var orbLayoutPending = false
    private var orbMotionGeneration = 0
    private var orbTarget = CGRect.zero
    private var orbClickMonitors: [Any] = []
    private var previousPlacement: PanelPlacement = .top
    private let monitorState = MonitorPanelState()
    private var dragging = false
    private var orbHoverSuppressedUntilExit = false
    private var dragExceededClickThreshold = false
    private var dragStart = CGPoint.zero
    private var dragPointerStart = CGPoint.zero
    private let themeReveal = ThemeReveal()
    private var displays: [DisplayChoice] = []
    private var chosen: DisplayChoice? {
        displays.first { $0.id == store.preferences.preferredDisplay } ?? displays.first(where: \.isPrimary) ?? displays.first
    }
    init(store: TaskStore) {
        self.store = store
        super.init()
        for panel in [top, floating] {
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.level = .floating; panel.animationBehavior = .utilityWindow
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        top.level = .statusBar
        top.animationBehavior = .none
        top.acceptsMouseMovedEvents = true
        floating.acceptsKeyboard = true
        floating.escapeAction = { [weak self] in self?.dismissExpanded() }
        top.escapeAction = { [weak self] in self?.dismissExpanded() }
        top.title = "Codex Top 监控任务"; floating.title = "Codex Top 悬浮任务"
        floating.isMovableByWindowBackground = false; floating.delegate = self
        let topView = HoverHostingView(rootView: TopPanelView(
            store: store, state: topState, monitorState: monitorState, open: { [weak self] in self?.toggleExpanded() },
            pickTasks: { [weak self] in self?.showPicker() }, settings: { [weak self] in self?.showSettings() }, finishedChanged: { [weak self] in
                self?.updateContentSize(animated: true)
            }).windowTypography())
        topView.sizingOptions = []
        topView.hoverChanged = { [weak self] value in self?.hoverTop(value) }
        top.contentView = topView
        let floatingView = HoverHostingView(rootView: FloatingPanelView(
            store: store, presentation: floatingPresentation, orbState: orbState, monitorState: monitorState,
            pickTasks: { [weak self] in self?.showPicker() }, settings: { [weak self] in self?.showSettings() }, openTasks: { [weak self] in self?.toggleExpanded() }, closeTasks: { [weak self] in self?.dismissExpanded() }, finishedChanged: { [weak self] in
                self?.updateContentSize(animated: true)
            }, dragStarted: { [weak self] translation in self?.beginDrag(initialTranslation: translation) }, dragMoved: { [weak self] in self?.moveDrag() }, dragEnded: { [weak self] in self?.endDrag() }).windowTypography())
        floatingView.sizingOptions = []
        floatingView.hoverChanged = { [weak self] value in self?.hoverFloating(value) }
        floatingView.contextMenuProvider = { [weak self] in
            guard let self, self.store.placement == .orb, !self.orbState.expanded else { return nil }
            return self.orbContextMenu
        }
        floating.contentView = floatingView
        store.onChange = { [weak self] in self?.updateContentSize(animated: true) }
        store.onDisplayChange = { [weak self] in self?.layout(recoverFloating: true) }
        store.onModeChange = { [weak self] in self?.applyMode() }
        store.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        store.onAppearanceWillChange = { [weak self] in self?.prepareThemeReveal() ?? false }
        store.onExternalNavigation = { [weak self] in
            guard let self, self.store.placement != .floating else { return }
            self.dismissExpanded()
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(recoverFloating: true) }
        }
        layout(recoverFloating: true)
        applyAppearance()
        applyMode()
    }
    func layout(recoverFloating: Bool, bringAuxiliaryToChosen: Bool = false) {
        themeReveal.cancel()
        cancelHoverTransitions()
        displays = DisplayChoice.available()
        guard let chosen else { return }
        positioning = true; defer { positioning = false }
        topHovered = false
        if store.placement == .orb && recoverFloating {
            let display = displays.first { $0.id == store.preferences.floatingDisplay } ?? chosen
            let anchor = WindowGeometry.floating(size: CGSize(width: 44, height: 44), visible: display.screen.visibleFrame, x: store.preferences.floatingX, y: store.preferences.floatingY)
            restoreCollapsedOrb(to: anchor)
        }
        updateContentSize()
        if store.placement == .top { top.orderFrontRegardless() }
        if recoverFloating && store.placement != .orb {
            let display = displays.first { $0.id == store.preferences.floatingDisplay } ?? chosen
            floating.setFrame(WindowGeometry.floating(size: floatingSize, visible: display.screen.visibleFrame, x: store.preferences.floatingX, y: store.preferences.floatingY), display: true)
        }
        if let settings { settings.contentView = NSHostingView(rootView: SettingsView(store: store, displays: displays, recoverWindows: { [weak self] in self?.recoverWindows() }).windowTypography()) }
        for window in [picker, settings].compactMap({ $0 }) {
            let frame = WindowGeometry.recoverUtilityWindow(window.frame, visibleFrames: displays.map { $0.screen.visibleFrame },
                                                            preferredVisible: chosen.screen.visibleFrame, forcePreferred: bringAuxiliaryToChosen)
            setFrame(frame, for: window, animated: false)
        }
    }
    private func panelHeight(compact: Bool) -> CGFloat {
        let includesFinished = compact ? monitorState.floatingFinished : monitorState.expandedFinished
        let rows = min(store.active.count + (includesFinished ? store.finished.count : 0), 4)
        let header = compact ? PanelMetrics.floatingHeader : PanelMetrics.expandedHeader
        let body = store.selected.isEmpty ? 195 : CGFloat(rows) * (compact ? PanelMetrics.floatingRow : PanelMetrics.expandedRow) + (store.finished.isEmpty ? 0 : PanelMetrics.disclosure)
        let height = header + body + (compact ? 4 : PanelMetrics.footer + 2)
        let messageScale = max(0.8, store.uiScale) / store.uiScale
        return height + (store.sourceWarning == nil ? 0 : 62 * messageScale) + (store.notice == nil ? 0 : 52 * messageScale)
    }
    private var floatingSize: CGSize {
        if store.placement == .orb { return CGSize(width: 44, height: 44) }
        return CGSize(width: PanelMetrics.floatingWidth * store.uiScale, height: panelHeight(compact: true) * store.uiScale)
    }
    private func updateContentSize(animated: Bool = false) {
        // Pinning uses only the floating window, including refresh/recovery paths.
        if store.placement == .floating { hideTopPanel() }
        guard let chosen else { return }
        let previousPositioning = positioning; positioning = true; defer { positioning = previousPositioning }
        let isPopover = store.placement == .menuBar
        let anchor = isPopover ? WindowGeometry.statusPanelAnchor(provider: statusAnchorProvider, screenFrames: displays.map { $0.screen.frame }, fallbackVisible: chosen.screen.visibleFrame) : .zero
        let display = isPopover ? displays.first { $0.screen.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? chosen : chosen
        let cameraHeight: CGFloat = isPopover ? 0 : chosen.notchHeight
        let cameraWidth: CGFloat = isPopover ? 0 : chosen.notchWidth
        let size = CGSize(width: max(PanelMetrics.expandedWidth * store.uiScale, cameraWidth + 32), height: panelHeight(compact: false) * store.uiScale + cameraHeight)
        let compactFrame: CGRect
        let expandedFrame: CGRect
        if isPopover {
            let desired = CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 8, width: size.width, height: size.height)
            expandedFrame = WindowGeometry.pixelAligned(WindowGeometry.clamp(desired, to: display.screen.visibleFrame), scale: display.screen.backingScaleFactor)
            // A status item owns its collapsed representation. Its popover only has
            // a full-size window, which is hidden after the closing transition.
            compactFrame = expandedFrame
        } else if store.placement == .top || store.placement == .floating {
            let frames = WindowGeometry.topPanelFrames(screen: chosen.screen.frame, visible: chosen.screen.visibleFrame,
                                                       scaledSize: size, notchWidth: cameraWidth, notchHeight: cameraHeight)
            compactFrame = frames.compact
            expandedFrame = frames.expanded
        } else {
            compactFrame = WindowGeometry.compact(screen: chosen.screen.frame, visible: chosen.screen.visibleFrame, notchWidth: cameraWidth, notchHeight: cameraHeight)
            expandedFrame = WindowGeometry.expanded(from: compactFrame, size: size, visible: chosen.screen.visibleFrame)
        }
        if topState.compactSize != compactFrame.size { topState.compactSize = compactFrame.size }
        if topState.expandedSize != expandedFrame.size { topState.expandedSize = expandedFrame.size }
        if topState.cameraWidth != cameraWidth { topState.cameraWidth = cameraWidth }
        if topState.cameraHeight != cameraHeight { topState.cameraHeight = cameraHeight }
        animateTop(to: topExpanded ? expandedFrame : compactFrame, progress: topExpanded ? 1 : 0, animated: animated)
        if store.placement == .orb {
            updateOrbLayout(animated: animated)
        } else if floating.frame.width > 0 && !dragging {
            let display = displays.first { $0.screen.visibleFrame.contains(CGPoint(x: floating.frame.midX, y: floating.frame.midY)) } ?? chosen
            let frame = CGRect(x: floating.frame.minX, y: floating.frame.maxY - floatingSize.height, width: floatingSize.width, height: floatingSize.height)
            setFrame(WindowGeometry.clamp(frame, to: display.screen.visibleFrame), for: floating, animated: animated)
        }
        if let picker {
            let size = CGSize(width: 450 * store.uiScale, height: 635 * store.uiScale)
            let frame = CGRect(x: picker.frame.minX, y: picker.frame.maxY - size.height, width: size.width, height: size.height)
            let recovered = WindowGeometry.recoverUtilityWindow(frame, visibleFrames: displays.map { $0.screen.visibleFrame },
                                                                preferredVisible: chosen.screen.visibleFrame)
            setFrame(recovered, for: picker, animated: animated)
        }
    }
    private func setOrbExpanded(_ value: Bool) {
        guard orbState.expanded != value else { return }
        // Prepare layout and the backing canvas before revealing the list. Content
        // and the surface then start in the same animation transaction.
        updateOrbLayout(animated: true, expanded: value)
        updateOrbClickMonitoring()
    }
    private func updateOrbClickMonitoring() {
        stopOrbClickMonitoring()
        guard store.placement == .orb, orbState.expanded else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Local and global monitors are complementary. Return the local event unchanged
        // so the same click still reaches the other window or application.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleOrbClick(event) }
            return event
        }) { orbClickMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.store.placement == .orb, self.orbState.expanded else { return }
                self.dismissExpanded()
            }
        }) { orbClickMonitors.append(monitor) }
    }
    private func stopOrbClickMonitoring() {
        orbClickMonitors.forEach { NSEvent.removeMonitor($0) }
        orbClickMonitors.removeAll()
    }
    private func handleOrbClick(_ event: NSEvent) {
        guard store.placement == .orb, orbState.expanded, !dragging else { return }
        if event.window === floating {
            let point = floating.convertPoint(toScreen: event.locationInWindow)
            // The backing window temporarily includes the ring and expanded endpoints.
            // Its transparent extra canvas is outside the task panel.
            if orbTarget.contains(point) { return }
        }
        dismissExpanded()
    }
    private func updateOrbLayout(animated: Bool, expanded requestedExpanded: Bool? = nil) {
        guard store.placement == .orb, !dragging, let chosen else { return }
        // Refresh/disclosure changes can arrive while the surface still presents an
        // intermediate frame. Do not rebase that frame from its model endpoint.
        // Explicit open/close commands remain interruptible.
        if orbMotion != nil && requestedExpanded == nil {
            orbLayoutPending = true
            return
        }
        let willExpand = requestedExpanded ?? orbState.expanded
        if orbAnchor.width == 0 { orbAnchor = floating.frame }
        let display = displays.first { $0.screen.frame.contains(CGPoint(x: orbAnchor.midX, y: orbAnchor.midY)) } ?? chosen
        orbAnchor = alignedOrb(WindowGeometry.clamp(orbAnchor, to: display.screen.visibleFrame), on: display)
        let size = CGSize(width: PanelMetrics.expandedWidth * store.uiScale, height: panelHeight(compact: false) * store.uiScale)
        let desired: CGRect
        let direction: OrbExpansionDirection
        if let openFrame = orbExpandedFrame, let openingDirection = orbExpansionDirection, willExpand {
            direction = openingDirection
            desired = WindowGeometry.resizedOrbPanel(from: openFrame, size: size, visible: display.screen.visibleFrame, direction: direction)
        } else {
            let layout = WindowGeometry.orbPanelLayout(from: orbAnchor, size: size, visible: display.screen.visibleFrame)
            desired = layout.frame; direction = layout.direction
        }
        let expanded = WindowGeometry.pixelAligned(desired, scale: display.screen.backingScaleFactor)
        if willExpand { orbExpandedFrame = expanded; orbExpansionDirection = direction }
        if willExpand || (!orbState.expanded && orbMotion == nil) {
            // Lay out the list once at its destination size. The outer surface owns
            // the morph; update the hidden endpoint before its first reveal too.
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                if orbState.expandedSize != expanded.size { orbState.expandedSize = expanded.size }
                if orbState.expansionDirection != direction { orbState.expansionDirection = direction }
            }
        }
        animateOrb(to: willExpand ? expanded : orbAnchor, expanded: willExpand, animated: animated)
    }
    private func restoreCollapsedOrb(to anchor: CGRect) {
        stopOrbClickMonitoring()
        orbHoverSuppressedUntilExit = false
        let display = displays.first { $0.screen.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? chosen
        let anchor = display.map { alignedOrb(anchor, on: $0) } ?? anchor
        cancelOrbMotion()
        orbCanvas = nil; orbAnchor = anchor; orbTarget = anchor; orbExpandedFrame = nil; orbExpansionDirection = nil
        orbLayoutPending = false
        let wasPositioning = positioning; positioning = true; defer { positioning = wasPositioning }
        // A cancelled morph can still have coordinates relative to its larger canvas.
        // Restore both the drawing surface and the native window before layout can early-return.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            orbState.expanded = false; orbState.hovered = false
            orbState.surfaceFrame = CGRect(origin: .zero, size: anchor.size)
        }
        floating.hasShadow = false
        floating.resignKey()
        floating.setFrame(anchor, display: true)
    }
    private func alignedOrb(_ frame: CGRect, on display: DisplayChoice) -> CGRect {
        let scale = display.screen.backingScaleFactor
        // Keep the 44pt circle square and align both axes to device pixels. Normalized
        // saved positions otherwise leave different fractional coverage on each edge.
        return CGRect(x: (frame.minX * scale).rounded() / scale,
                      y: (frame.minY * scale).rounded() / scale, width: 44, height: 44)
    }
    private func cancelOrbMotion() {
        orbMotionGeneration &+= 1
        orbMotion = nil
    }
    private func animateOrb(to target: CGRect, expanded: Bool, animated: Bool) {
        let frame = floating.frame
        let tolerance = 1 / (floating.screen?.backingScaleFactor ?? 1)
        let reached = abs(frame.minX - target.minX) <= tolerance && abs(frame.minY - target.minY) <= tolerance &&
            abs(frame.width - target.width) <= tolerance && abs(frame.height - target.height) <= tolerance
        // AppKit can quantize a window frame. A periodic data refresh must not replay
        // the morph just because the unchanged target differs by a fraction of a pixel.
        guard expanded != orbState.expanded || target != orbTarget || !reached && orbMotion == nil else { return }
        themeReveal.cancel()
        cancelOrbMotion(); orbTarget = target
        let wasPositioning = positioning; positioning = true; defer { positioning = wasPositioning }
        guard animated, floating.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { orbState.expanded = expanded }
            floating.hasShadow = expanded
            commitOrbCanvas(target, surface: CGRect(origin: .zero, size: target.size))
            orbCanvas = nil
            finishOrbLayout()
            return
        }
        let oldCanvas = orbCanvas ?? floating.frame
        let canvas = oldCanvas.union(target)
        // Rebase without animation: the visible surface stays at the same screen point
        // while its backing window grows to contain both endpoints.
        if orbCanvas == nil || canvas != oldCanvas {
            var rect = orbState.surfaceFrame
            rect.origin.x += oldCanvas.minX - canvas.minX
            rect.origin.y += canvas.maxY - oldCanvas.maxY
            commitOrbCanvas(canvas, surface: rect)
        }
        orbCanvas = canvas
        let surface = CGRect(x: target.minX - canvas.minX, y: canvas.maxY - target.maxY, width: target.width, height: target.height)
        let response = expanded ? 0.32 : 0.28
        let generation = orbMotionGeneration
        orbMotion = generation
        floating.hasShadow = expanded
        withAnimation(.spring(response: response, dampingFraction: 1, blendDuration: 0), completionCriteria: .removed) {
            orbState.expanded = expanded
            orbState.surfaceFrame = surface
        } completion: { [weak self] in
            guard let self, self.store.placement == .orb, self.orbMotion == generation,
                  self.orbMotionGeneration == generation, self.orbTarget == target else { return }
            let wasPositioning = self.positioning
            self.positioning = true; defer { self.positioning = wasPositioning }
            self.commitOrbCanvas(target, surface: CGRect(origin: .zero, size: target.size))
            self.orbCanvas = nil; self.orbMotion = nil
            self.finishOrbLayout()
        }
    }
    private func finishOrbLayout() {
        if !orbState.expanded { orbExpandedFrame = nil; orbExpansionDirection = nil }
        guard orbLayoutPending else { return }
        orbLayoutPending = false
        updateOrbLayout(animated: true)
    }
    private func commitOrbCanvas(_ frame: CGRect, surface: CGRect) {
        // Rebase SwiftUI and AppKit in one display transaction. display:true used
        // to flush the resized window before its content consumed the new origin.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { orbState.surfaceFrame = surface }
            floating.setFrame(frame, display: false)
            floating.contentView?.layoutSubtreeIfNeeded()
        }
        floating.invalidateShadow()
    }
    private func setFrame(_ frame: CGRect, for window: NSWindow, animated: Bool) {
        guard window.frame != frame else { return }
        themeReveal.cancel()
        window.setFrame(frame, display: true, animate: animated && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// SwiftUI animates the surface at the display refresh rate. AppKit only prepares the canvas
    /// and trims it at completion, avoiding a resize and layout of the whole window every 16ms.
    private func animateTop(to target: CGRect, progress targetProgress: CGFloat, animated: Bool) {
        if store.placement == .menuBar {
            animateStatusPopover(to: target, progress: targetProgress, animated: animated)
            return
        }
        if topTarget == target && topState.progress == targetProgress && topState.surfaceSize == target.size { return }
        themeReveal.cancel()
        topMotion?.cancel(); topMotion = nil; topTarget = target
        guard animated, top.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            topState.surfaceSize = target.size; topState.progress = targetProgress
            top.setFrame(target, display: true)
            return
        }
        let width = max(top.frame.width, target.width), height = max(top.frame.height, target.height)
        top.setFrame(CGRect(x: target.midX - width / 2, y: target.maxY - height, width: width, height: height), display: true)
        let duration = targetProgress > 0 ? 0.24 : 0.20
        withAnimation(.smooth(duration: duration)) {
            topState.surfaceSize = target.size; topState.progress = targetProgress
        }
        topMotion = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.02))
            guard !Task.isCancelled, let self else { return }
            self.top.setFrame(target, display: true)
            self.topMotion = nil
            if !self.topExpanded { self.top.resignKey() }
            if !self.topExpanded && self.store.placement != .top { self.top.orderOut(nil) }
        }
    }
    private func animateStatusPopover(to target: CGRect, progress targetProgress: CGFloat, animated: Bool) {
        let unchanged = topTarget == target && topState.progress == targetProgress && topState.surfaceSize == target.size
        if unchanged && (animated || topMotion == nil) {
            if targetProgress == 0 && topMotion == nil { top.orderOut(nil) }
            return
        }
        themeReveal.cancel()
        topMotion?.cancel(); topMotion = nil
        topTarget = target
        topState.surfaceSize = target.size
        if top.frame != target { top.setFrame(target, display: true) }
        guard animated, top.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { topState.progress = targetProgress }
            if targetProgress == 0 { top.orderOut(nil) }
            return
        }
        let duration = targetProgress > 0 ? 0.20 : 0.16
        withAnimation(.easeInOut(duration: duration)) { topState.progress = targetProgress }
        topMotion = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration + 0.02)) } catch { return }
            guard !Task.isCancelled, let self, self.store.placement == .menuBar else { return }
            self.topMotion = nil
            if !self.topExpanded { self.top.resignKey(); self.top.orderOut(nil) }
        }
    }
    func applyMode() {
        themeReveal.cancel()
        cancelHoverTransitions()
        topMotion?.cancel(); topMotion = nil
        stopOrbClickMonitoring()
        let unpinningToTop = previousPlacement == .floating && store.placement == .top
        let wasPositioning = positioning; positioning = true
        cancelOrbMotion(); orbCanvas = nil
        if previousPlacement == .orb && orbAnchor.width > 0 { restoreCollapsedOrb(to: orbAnchor) }
        orbState.expanded = false
        if store.placement == .orb {
            let frame = floating.frame
            let display = displays.first { $0.screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? chosen
            if let display {
                let anchor = WindowGeometry.clamp(CGRect(x: frame.midX - 22, y: frame.midY - 22, width: 44, height: 44), to: display.screen.visibleFrame)
                restoreCollapsedOrb(to: anchor)
            }
        }
        floating.hasShadow = store.placement != .orb
        previousPlacement = store.placement
        positioning = wasPositioning
        topHovered = false; orbState.hovered = false; orbHoverSuppressedUntilExit = false
        if store.placement == .floating || store.placement == .orb {
            dismissExpanded(); floatingDismissTask?.cancel()
            floating.orderFrontRegardless(); floating.contentView?.layoutSubtreeIfNeeded(); floating.displayIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                guard let self, [.floating, .orb].contains(self.store.placement) else { return }
                self.floatingPresentation.visible = true
            }
        } else {
            floatingPresentation.visible = false
            floatingDismissTask?.cancel()
            if unpinningToTop {
                // Do not leave two task surfaces visible during the unpin transition.
                floatingDismissTask = nil; floating.orderOut(nil)
            } else {
                floatingDismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(240))
                    guard !Task.isCancelled, let self, ![.floating, .orb].contains(self.store.placement) else { return }
                    self.floating.orderOut(nil)
                }
            }
        }
        if store.placement == .top { top.orderFrontRegardless() }
        else { hideTopPanel() }
        updateContentSize(animated: true)
    }
    private func hideTopPanel() {
        cancelHoverTransitions()
        topMotion?.cancel(); topMotion = nil
        topExpanded = false; topHovered = false
        if top.isKeyWindow { top.resignKey() }
        top.acceptsKeyboard = false
        if top.isVisible { top.orderOut(nil) }
    }
    private func applyAppearance() {
        let appearance = NSAppearance(named: store.theme == .light ? .aqua : .darkAqua)
        for window in [top, floating, picker, settings].compactMap({ $0 }) { window.appearance = appearance }
        themeReveal.reveal()
    }
    private func prepareThemeReveal() -> Bool {
        let windows = [settings, picker, floating, top].compactMap { $0 }.filter(\.isVisible)
        let event = NSApp.currentEvent
        let clickedWindow = event.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0.window : nil }
        guard let window = windows.first(where: { $0 === clickedWindow }) ?? windows.first(where: \.isKeyWindow) ?? windows.first else { return false }
        let point = event.flatMap { $0.window === window && [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0.locationInWindow : nil }
        let topSurface = window === top && store.placement != .menuBar
        let orbSurface = window === floating && store.placement == .orb
        // Match the live surface's physical corners, including its outer scale.
        let radius: CGFloat = window === settings ? 0 : topSurface ? 12 + 10 * topState.progress
            : orbSurface ? 22 : 20 * store.uiScale
        return themeReveal.prepare(window: window, oldTheme: store.theme, pointInWindow: point,
                                   cornerRadius: radius, squareTop: topSurface && topState.cameraHeight > 0,
                                   circularCorners: orbSurface)
    }
    func toggleExpanded() {
        hideTask?.cancel(); revealTask?.cancel()
        if store.placement == .floating { floating.makeKeyAndOrderFront(nil); return }
        if store.placement == .orb {
            if orbState.expanded { dismissExpanded() }
            else { revealExpanded(); floating.makeKeyAndOrderFront(nil) }
            return
        }
        if topExpanded { dismissExpanded() }
        else { revealExpanded(); top.acceptsKeyboard = true; top.makeKeyAndOrderFront(nil) }
    }
    private func revealExpanded() {
        guard store.placement != .floating, !dragging else { return }
        if store.placement == .orb {
            hideTask?.cancel()
            setOrbExpanded(true)
            return
        }
        if !top.isVisible { topExpanded = false; updateContentSize(); top.orderFrontRegardless() }
        hideTask?.cancel(); topExpanded = true
        top.orderFrontRegardless(); updateContentSize(animated: true)
    }
    private func dismissExpanded() {
        revealTask?.cancel(); revealTask = nil
        if store.placement == .orb {
            floating.resignKey()
            setOrbExpanded(false)
            return
        }
        topExpanded = false
        top.resignKey(); top.acceptsKeyboard = false
        updateContentSize(animated: true)
    }
    private func hoverTop(_ value: Bool) {
        guard store.placement == .top else { return }
        topHovered = value
        revealTask?.cancel()
        if value && canRevealOnHover {
            hideTask?.cancel()
            let placement = store.placement
            revealTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, self.topHovered,
                      self.store.placement == placement, self.canRevealOnHover else { return }
                self.revealExpanded()
            }
        } else { scheduleHide() }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard store.placement == .top else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, !self.topHovered,
                  self.store.placement == .top else { return }
            self.dismissExpanded()
        }
    }
    func toggleStatusPanel() {
        guard store.placement == .menuBar else { return }
        cancelHoverTransitions()
        toggleExpanded()
    }
    private func hoverFloating(_ value: Bool) {
        guard store.placement == .orb else { return }
        if !value {
            orbState.hovered = false
            // Ignore tracking exits caused only by moving/clamping the backing window.
            if !dragging && !floating.frame.contains(NSEvent.mouseLocation) { orbHoverSuppressedUntilExit = false }
            return
        }
        guard !dragging, !orbHoverSuppressedUntilExit else { return }
        orbState.hovered = true
    }
    private var canRevealOnHover: Bool {
        !dragging && picker?.isVisible != true && settings?.isVisible != true
    }
    private func cancelHoverTransitions() {
        hideTask?.cancel(); hideTask = nil
        revealTask?.cancel(); revealTask = nil
    }
    private func beginDrag(initialTranslation: CGSize) {
        guard store.placement == .orb || store.placement == .floating else { return }
        if store.placement == .orb && orbMotion != nil { return }
        themeReveal.cancel(); savePositionTask?.cancel()
        dragging = true; dragStart = floating.frame.origin; orbState.hovered = false
        dragExceededClickThreshold = false
        if store.placement == .orb { orbHoverSuppressedUntilExit = true }
        let point = dragPointerLocation
        // SwiftUI's first onChanged may already contain a short drag. Convert its
        // downward-positive translation back to the original AppKit mouse-down point.
        dragPointerStart = CGPoint(x: point.x - initialTranslation.width, y: point.y + initialTranslation.height)
        hideTask?.cancel(); revealTask?.cancel()
        if store.placement == .floating { dismissExpanded() }
    }
    private func moveDrag() {
        guard dragging else { return }
        let point = dragPointerLocation
        var origin = CGPoint(x: dragStart.x + point.x - dragPointerStart.x, y: dragStart.y + point.y - dragPointerStart.y)
        if hypot(origin.x - dragStart.x, origin.y - dragStart.y) >= 4 { dragExceededClickThreshold = true }
        if let display = displays.first(where: { $0.screen.frame.contains(point) }) {
            origin.y = min(origin.y, display.screen.visibleFrame.maxY - floating.frame.height)
        }
        moveFloatingFrameForDrag(CGRect(origin: origin, size: floating.frame.size))
    }
    private func endDrag() {
        guard dragging else { return }
        let pointer = dragPointerLocation
        let moved = dragExceededClickThreshold || hypot(pointer.x - dragPointerStart.x, pointer.y - dragPointerStart.y) >= 4 ||
            hypot(floating.frame.minX - dragStart.x, floating.frame.minY - dragStart.y) >= 4
        if let display = displays.first(where: { $0.screen.frame.contains(pointer) }) ??
            displays.first(where: { $0.screen.frame.contains(CGPoint(x: floating.frame.midX, y: floating.frame.midY)) }) ?? chosen {
            let frame = WindowGeometry.clamp(floating.frame, to: display.screen.visibleFrame)
            let target = store.placement == .orb && !orbState.expanded ? alignedOrb(frame, on: display) : frame
            moveFloatingFrameForDrag(target)
        }
        dragging = false
        persistFloatingPosition()
        let pointerInsideOrb = store.placement == .orb && !orbState.expanded && floating.frame.contains(pointer)
        orbHoverSuppressedUntilExit = moved && pointerInsideOrb
        orbState.hovered = !moved && pointerInsideOrb
        if store.placement == .orb && !orbState.expanded && !moved { toggleExpanded() }
        else { updateContentSize(animated: true) }
    }
    private func moveFloatingFrameForDrag(_ frame: CGRect) {
        let previous = floating.frame
        guard previous != frame else { return }
        if previous.size == frame.size { floating.setFrameOrigin(frame.origin) }
        else { floating.setFrame(frame, display: false) }
        guard store.placement == .orb else { return }
        let actual = floating.frame
        if orbState.expanded {
            orbAnchor = WindowGeometry.movingOrbAnchor(orbAnchor, from: previous, to: actual, direction: orbExpansionDirection ?? .down)
            orbExpandedFrame = actual
        } else {
            orbAnchor = actual
        }
        // Dragging starts only after a morph finishes, so no larger canvas remains.
        // Keep every screen-space target in sync before a data refresh can lay out.
        orbTarget = actual; orbCanvas = nil
        if previous.size != actual.size {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                orbState.surfaceFrame = CGRect(origin: .zero, size: actual.size)
                if orbState.expanded { orbState.expandedSize = actual.size }
            }
            floating.contentView?.layoutSubtreeIfNeeded()
            floating.displayIfNeeded()
        }
    }
    /// Use the delivered mouse event, so movement follows its coordinates even when
    /// the system pointer is updated on a different schedule (for example remote input).
    private var dragPointerLocation: CGPoint {
        if let event = NSApp.currentEvent, let window = event.window,
           [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }
    private func persistFloatingPosition() {
        let frame = store.placement == .orb ? orbAnchor : floating.frame
        guard let screen = displays.first(where: { $0.screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return }
        let visible = screen.screen.visibleFrame
        store.saveFloatingPosition(display: screen.id, x: Double((frame.minX - visible.minX) / max(1, visible.width - frame.width)), y: Double((frame.minY - visible.minY) / max(1, visible.height - frame.height)))
    }
    func showPicker() {
        cancelHoverTransitions()
        if let picker, picker.isVisible { picker.makeKeyAndOrderFront(nil); return }
        dismissExpanded()
        let window = makeWindow(title: "选择监控任务", size: CGSize(width: 450 * store.uiScale, height: 635 * store.uiScale), popover: true)
        window.contentView = NSHostingView(rootView: TaskPickerView(store: store, close: { [weak self] in self?.picker?.close(); self?.picker = nil }).windowTypography())
        picker = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func showSettings() {
        // Resolve the pointer's display before activation can change the main screen.
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let target = screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? screens.first { $0 == settings?.screen } ?? NSScreen.main ?? screens.first
        cancelHoverTransitions()
        if settings?.isVisible != true { dismissExpanded() }
        let window: NSWindow
        if let settings { window = settings }
        else {
            window = makeWindow(title: "Codex Top · 设置", size: CGSize(width: 500, height: 610), screen: target)
            window.contentView = NSHostingView(rootView: SettingsView(store: store, displays: displays, recoverWindows: { [weak self] in self?.recoverWindows() }).windowTypography())
            settings = window
        }
        if let target, !window.isVisible || !target.visibleFrame.contains(window.frame) {
            let visible = target.visibleFrame
            let frame = CGRect(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2,
                               width: window.frame.width, height: window.frame.height)
            window.setFrame(WindowGeometry.clamp(frame, to: visible), display: false)
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func makeWindow(title: String, size: CGSize, popover: Bool = false, screen: NSScreen? = nil) -> NSWindow {
        let window: NSWindow
        if popover {
            let panel = UtilityPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.acceptsKeyboard = true; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        }
        window.title = title; window.isReleasedWhenClosed = false
        window.minSize = popover ? NSSize(width: 300, height: 320) : NSSize(width: 420, height: 400)
        window.appearance = NSAppearance(named: store.theme == .light ? .aqua : .darkAqua); window.level = .floating
        if let screen = screen ?? chosen?.screen {
            let visible = screen.visibleFrame
            window.setFrame(WindowGeometry.clamp(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), to: visible), display: false)
        } else { window.center() }
        return window
    }
    func recoverWindows() {
        if let chosen { store.saveFloatingPosition(display: chosen.id, x: 0.7, y: 0.7) }
        layout(recoverFloating: true, bringAuxiliaryToChosen: true)
        if [.floating, .orb].contains(store.placement) { floatingDismissTask?.cancel(); floatingPresentation.visible = true; floating.orderFrontRegardless() } else { revealExpanded() }
    }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, notification.object as? NSWindow === floating else { return }
        if store.placement == .orb && (orbState.expanded || orbMotion != nil) { return }
        if dragging { return }
        savePositionTask?.cancel()
        savePositionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persistFloatingPosition()
        }
    }
}
