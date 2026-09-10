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
        return super.performKeyEquivalent(with: event)
    }
}

// Always-active AppKit tracking also receives hover while another application is key.
// The small top panel must never need a click merely to activate SwiftUI tracking.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var hoverChanged: (Bool) -> Void = { _ in }
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
}

@MainActor final class WindowController: NSObject, NSWindowDelegate {
    let store: TaskStore
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
    private var orbHovered = false
    private var orbHoverSuppressed = false
    private let orbState = OrbMorphState()
    private var orbAnchor = CGRect.zero
    private var orbCanvas: CGRect?
    private var orbMotion: Task<Void, Never>?
    private var orbTarget = CGRect.zero
    private var previousPlacement: PanelPlacement = .top
    private let monitorState = MonitorPanelState()
    private var dragging = false
    private var dragStart = CGPoint.zero
    private var dragPointerStart = CGPoint.zero
    private var dockCandidate: DisplayChoice?
    private var statusAnchor: CGRect?
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
            }))
        topView.sizingOptions = []
        topView.hoverChanged = { [weak self] value in self?.hoverTop(value) }
        top.contentView = topView
        let floatingView = HoverHostingView(rootView: FloatingPanelView(
            store: store, presentation: floatingPresentation, orbState: orbState, monitorState: monitorState,
            pickTasks: { [weak self] in self?.showPicker() }, settings: { [weak self] in self?.showSettings() }, openTasks: { [weak self] in self?.toggleExpanded() }, closeTasks: { [weak self] in self?.dismissExpanded() }, finishedChanged: { [weak self] in
                self?.updateContentSize(animated: true)
            }, dragStarted: { [weak self] in self?.beginDrag() }, dragMoved: { [weak self] in self?.moveDrag() }, dragEnded: { [weak self] in self?.endDrag() }))
        floatingView.sizingOptions = []
        floatingView.hoverChanged = { [weak self] value in self?.hoverFloating(value) }
        floating.contentView = floatingView
        store.onChange = { [weak self] in self?.updateContentSize(animated: true) }
        store.onDisplayChange = { [weak self] in self?.layout(recoverFloating: true) }
        store.onModeChange = { [weak self] in self?.applyMode() }
        store.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(recoverFloating: true) }
        }
        layout(recoverFloating: true)
        applyAppearance()
        applyMode()
    }
    func layout(recoverFloating: Bool) {
        cancelHoverTransitions()
        displays = DisplayChoice.available()
        guard let chosen else { return }
        positioning = true; defer { positioning = false }
        topHovered = false; orbHovered = false
        if store.placement == .orb && recoverFloating {
            let display = displays.first { $0.id == store.preferences.floatingDisplay } ?? chosen
            let anchor = WindowGeometry.floating(size: CGSize(width: 44, height: 44), visible: display.screen.visibleFrame, x: store.preferences.floatingX, y: store.preferences.floatingY)
            restoreCollapsedOrb(to: anchor)
        }
        updateContentSize()
        if store.placement == .top || store.placement == .floating { top.orderFrontRegardless() }
        if recoverFloating && store.placement != .orb {
            let display = displays.first { $0.id == store.preferences.floatingDisplay } ?? chosen
            floating.setFrame(WindowGeometry.floating(size: floatingSize, visible: display.screen.visibleFrame, x: store.preferences.floatingX, y: store.preferences.floatingY), display: true)
        }
        if let settings { settings.contentView = NSHostingView(rootView: SettingsView(store: store, displays: displays, recoverWindows: { [weak self] in self?.recoverWindows() })) }
        for window in [picker, settings].compactMap({ $0 }) {
            // An open settings/selection window must also survive a disconnected display.
            if !displays.contains(where: { $0.screen.visibleFrame.intersects(window.frame) }) {
                window.setFrame(WindowGeometry.clamp(window.frame, to: chosen.screen.visibleFrame), display: true)
            }
        }
    }
    private func panelHeight(compact: Bool) -> CGFloat {
        let includesFinished = compact ? monitorState.floatingFinished : monitorState.expandedFinished
        let rows = min(store.active.count + (includesFinished ? store.finished.count : 0), 4)
        let header = compact ? PanelMetrics.floatingHeader : PanelMetrics.expandedHeader
        let body = store.selected.isEmpty ? 195 : CGFloat(rows) * (compact ? PanelMetrics.floatingRow : PanelMetrics.expandedRow) + (store.finished.isEmpty ? 0 : PanelMetrics.disclosure)
        let height = header + body + (compact ? 4 : PanelMetrics.footer + 2)
        return height + (store.sourceWarning == nil ? 0 : 62) + (store.notice == nil ? 0 : 52)
    }
    private var floatingSize: CGSize {
        if store.placement == .orb { return CGSize(width: 44, height: 44) }
        return CGSize(width: PanelMetrics.floatingWidth * store.uiScale, height: panelHeight(compact: true) * store.uiScale)
    }
    private func updateContentSize(animated: Bool = false) {
        guard let chosen else { return }
        let previousPositioning = positioning; positioning = true; defer { positioning = previousPositioning }
        let isPopover = store.placement == .menuBar
        let anchor = statusAnchor ?? CGRect(x: chosen.screen.visibleFrame.midX, y: chosen.screen.visibleFrame.maxY, width: 24, height: 24)
        let display = isPopover ? displays.first { $0.screen.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? chosen : chosen
        let cameraHeight: CGFloat = isPopover ? 0 : chosen.notchHeight
        let cameraWidth: CGFloat = isPopover ? 0 : chosen.notchWidth
        let size = CGSize(width: max(PanelMetrics.expandedWidth * store.uiScale, cameraWidth + 32), height: panelHeight(compact: false) * store.uiScale + cameraHeight)
        let compactFrame: CGRect
        let expandedFrame: CGRect
        if isPopover {
            let desired = CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 8, width: size.width, height: size.height)
            expandedFrame = WindowGeometry.clamp(desired, to: display.screen.visibleFrame)
            compactFrame = CGRect(x: expandedFrame.midX - 22, y: expandedFrame.maxY - 22, width: 44, height: 22)
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
            let display = displays.first { $0.screen.frame.contains(CGPoint(x: picker.frame.midX, y: picker.frame.midY)) } ?? chosen
            let frame = CGRect(x: picker.frame.minX, y: picker.frame.maxY - size.height, width: size.width, height: size.height)
            setFrame(WindowGeometry.clamp(frame, to: display.screen.visibleFrame), for: picker, animated: animated)
        }
    }
    private func setOrbExpanded(_ value: Bool) {
        guard orbState.expanded != value else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: value ? 0.26 : 0.22)) {
            orbState.expanded = value
        }
        updateOrbLayout(animated: true)
    }
    private func updateOrbLayout(animated: Bool) {
        guard store.placement == .orb, !dragging, let chosen else { return }
        if orbAnchor.width == 0 { orbAnchor = floating.frame }
        let display = displays.first { $0.screen.frame.contains(CGPoint(x: orbAnchor.midX, y: orbAnchor.midY)) } ?? chosen
        orbAnchor = WindowGeometry.clamp(orbAnchor, to: display.screen.visibleFrame)
        let size = CGSize(width: PanelMetrics.expandedWidth * store.uiScale, height: panelHeight(compact: false) * store.uiScale)
        let expanded = WindowGeometry.expandedOrb(from: orbAnchor, size: size, visible: display.screen.visibleFrame)
        if orbState.expandedSize != expanded.size { orbState.expandedSize = expanded.size }
        animateOrb(to: orbState.expanded ? expanded : orbAnchor, animated: animated)
    }
    private func restoreCollapsedOrb(to anchor: CGRect) {
        orbMotion?.cancel(); orbMotion = nil
        orbCanvas = nil; orbAnchor = anchor; orbTarget = anchor
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
    private func animateOrb(to target: CGRect, animated: Bool) {
        guard target != orbTarget || floating.frame != target && orbMotion == nil else { return }
        orbMotion?.cancel(); orbMotion = nil; orbTarget = target
        let wasPositioning = positioning; positioning = true; defer { positioning = wasPositioning }
        floating.hasShadow = orbState.expanded
        guard animated, floating.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            floating.setFrame(target, display: true)
            orbCanvas = nil
            orbState.surfaceFrame = CGRect(origin: .zero, size: target.size)
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
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { orbState.surfaceFrame = rect }
            floating.setFrame(canvas, display: true)
        }
        orbCanvas = canvas
        let surface = CGRect(x: target.minX - canvas.minX, y: canvas.maxY - target.maxY, width: target.width, height: target.height)
        let duration = orbState.expanded ? 0.26 : 0.22
        withAnimation(.smooth(duration: duration)) { orbState.surfaceFrame = surface }
        orbMotion = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.03))
            guard !Task.isCancelled, let self, self.store.placement == .orb else { return }
            self.positioning = true
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { self.orbState.surfaceFrame = CGRect(origin: .zero, size: target.size) }
            self.floating.setFrame(target, display: true)
            self.orbCanvas = nil; self.orbMotion = nil
            self.positioning = false
        }
    }
    private func setFrame(_ frame: CGRect, for window: NSWindow, animated: Bool) {
        guard window.frame != frame else { return }
        window.setFrame(frame, display: true, animate: animated && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// SwiftUI animates the surface at the display refresh rate. AppKit only prepares the canvas
    /// and trims it at completion, avoiding a resize and layout of the whole window every 16ms.
    private func animateTop(to target: CGRect, progress targetProgress: CGFloat, animated: Bool) {
        if topTarget == target && topState.progress == targetProgress && topState.surfaceSize == target.size { return }
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
            if !self.topExpanded && [.orb, .menuBar].contains(self.store.placement) { self.top.orderOut(nil) }
        }
    }
    func applyMode() {
        cancelHoverTransitions()
        let wasPositioning = positioning; positioning = true
        orbMotion?.cancel(); orbMotion = nil; orbCanvas = nil
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
        orbHovered = false; topHovered = false; orbHoverSuppressed = false
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
            floatingDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled, let self, ![.floating, .orb].contains(self.store.placement) else { return }
                self.floating.orderOut(nil)
            }
        }
        if store.placement == .top || store.placement == .floating { top.orderFrontRegardless() }
        else { topExpanded = false; top.orderOut(nil) }
        updateContentSize(animated: true)
    }
    private func applyAppearance() {
        let appearance = NSAppearance(named: store.theme == .light ? .aqua : .darkAqua)
        for window in [top, floating, picker, settings].compactMap({ $0 }) { window.appearance = appearance }
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
    private func dismissExpanded(suppressHover: Bool = true) {
        revealTask?.cancel(); revealTask = nil
        if store.placement == .orb {
            if orbState.expanded && suppressHover { orbHoverSuppressed = true }
            floating.resignKey()
            setOrbExpanded(false)
            return
        }
        topExpanded = false
        top.resignKey(); top.acceptsKeyboard = false
        updateContentSize(animated: true)
    }
    private func hoverTop(_ value: Bool) {
        topHovered = value
        revealTask?.cancel()
        if value && [.top, .menuBar].contains(store.placement) && canRevealOnHover {
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
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, !self.topHovered, !self.orbHovered else { return }
            self.dismissExpanded(suppressHover: false)
        }
    }
    func toggleStatusPanel(anchor: CGRect?) {
        statusAnchor = anchor
        toggleExpanded()
    }
    private func hoverFloating(_ value: Bool) {
        guard store.placement == .orb, !dragging else { return }
        orbHovered = value
        orbState.hovered = value
        revealTask?.cancel()
        if !value { orbHoverSuppressed = false }
        if value && orbHoverSuppressed { return }
        if value && canRevealOnHover {
            hideTask?.cancel()
            revealTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self, self.orbHovered,
                      self.store.placement == .orb, self.canRevealOnHover else { return }
                self.revealExpanded()
            }
        } else { scheduleHide() }
    }
    private var canRevealOnHover: Bool {
        !dragging && picker?.isVisible != true && settings?.isVisible != true
    }
    private func cancelHoverTransitions() {
        hideTask?.cancel(); hideTask = nil
        revealTask?.cancel(); revealTask = nil
    }
    private func beginDrag() {
        if store.placement == .orb && (orbState.expanded || orbMotion != nil) { return }
        dragging = true; dragStart = floating.frame.origin; orbHovered = false
        dragPointerStart = dragPointerLocation
        hideTask?.cancel(); revealTask?.cancel(); dismissExpanded()
    }
    private func moveDrag() {
        guard dragging else { return }
        let point = dragPointerLocation
        var origin = CGPoint(x: dragStart.x + point.x - dragPointerStart.x, y: dragStart.y + point.y - dragPointerStart.y)
        if let display = displays.first(where: { $0.screen.frame.contains(point) }) {
            origin.y = min(origin.y, display.screen.visibleFrame.maxY - floating.frame.height)
        }
        floating.setFrameOrigin(origin)
        if store.placement == .orb { orbAnchor = floating.frame }
        updateDockCandidate()
    }
    private func endDrag() {
        guard dragging else { return }
        // Window-move notifications may arrive after mouse-up. Recompute from the final
        // frame rather than depending on the notification that displayed the hint.
        updateDockCandidate()
        dragging = false
        let target = dockCandidate
        let moved = hypot(floating.frame.minX - dragStart.x, floating.frame.minY - dragStart.y) >= 4
        dockCandidate = nil; store.dockingHint = false
        if moved, let target, WindowGeometry.shouldDock(floating.frame, to: target.screen.visibleFrame) {
            store.dockToMenuBar(display: target.id)
        } else {
            if let display = displays.first(where: { $0.screen.frame.contains(CGPoint(x: floating.frame.midX, y: floating.frame.midY)) }) ?? chosen {
                floating.setFrame(WindowGeometry.clamp(floating.frame, to: display.screen.visibleFrame), display: true)
            }
            if store.placement == .orb { orbAnchor = floating.frame }
            persistFloatingPosition()
            orbHovered = store.placement == .orb && floating.frame.contains(dragPointerLocation)
            if store.placement == .orb && !moved { toggleExpanded() }
        }
    }
    private func updateDockCandidate() {
        let center = CGPoint(x: floating.frame.midX, y: floating.frame.midY)
        dockCandidate = displays.first {
            $0.screen.frame.contains(center) && WindowGeometry.shouldDock(floating.frame, to: $0.screen.visibleFrame)
        }
        let hint = dockCandidate != nil
        if store.dockingHint != hint { store.dockingHint = hint }
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
        window.contentView = NSHostingView(rootView: TaskPickerView(store: store, close: { [weak self] in self?.picker?.close(); self?.picker = nil }))
        picker = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func showSettings() {
        cancelHoverTransitions()
        if let settings, settings.isVisible { settings.makeKeyAndOrderFront(nil); return }
        dismissExpanded()
        let window = makeWindow(title: "Codex Top · 设置", size: CGSize(width: 500, height: 610))
        window.contentView = NSHostingView(rootView: SettingsView(store: store, displays: displays, recoverWindows: { [weak self] in self?.recoverWindows() }))
        settings = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func makeWindow(title: String, size: CGSize, popover: Bool = false) -> NSWindow {
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
        if let chosen {
            let visible = chosen.screen.visibleFrame
            window.setFrame(WindowGeometry.clamp(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), to: visible), display: false)
        } else { window.center() }
        return window
    }
    func recoverWindows() {
        if let chosen { store.saveFloatingPosition(display: chosen.id, x: 0.7, y: 0.7) }
        layout(recoverFloating: true)
        if [.floating, .orb].contains(store.placement) { floatingDismissTask?.cancel(); floatingPresentation.visible = true; floating.orderFrontRegardless() } else { revealExpanded() }
    }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, notification.object as? NSWindow === floating else { return }
        if store.placement == .orb && (orbState.expanded || orbMotion != nil) { return }
        if dragging {
            updateDockCandidate()
            return
        }
        savePositionTask?.cancel()
        savePositionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persistFloatingPosition()
        }
    }
}
