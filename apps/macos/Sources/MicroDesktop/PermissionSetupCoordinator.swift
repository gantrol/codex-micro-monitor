import AppKit

@MainActor private final class PermissionSetupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Session-local dismissal prevents repeated prompts. A real grant rearms the
/// guide for a later revocation; no persisted "completed" bit masks lost access.
@MainActor final class PermissionSetupCoordinator: NSObject, NSWindowDelegate {
    private let model = PermissionSetupModel()
    private var window: NSWindow?
    private var polling: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var dismissedRequirement = false
    private var suspended = false
    private var isDragging = false
    private var flowStartedAt: TimeInterval?
    private var lastSettingsFrameAt: TimeInterval?
    private var lastPermissionCheck: TimeInterval = -.infinity

    init(trustChanged: (@MainActor (Bool) -> Void)? = nil) {
        super.init()
        model.trustChanged = trustChanged
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suspended else { return }
                self.refresh()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSettingsPlacement() }
        })
        refresh()
    }

    func refresh() {
        guard !suspended else { return }
        model.refresh()
        if model.status == .granted { dismissedRequirement = false }
        if model.status == .required, !dismissedRequirement, window == nil { show() }
    }

    func show() {
        suspended = false
        model.refresh()
        if window == nil {
            let window = PermissionSetupPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 390),
                                  styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = Bundle.main.localizedString(forKey: "permissionSetup", value: nil, table: nil)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentViewController = PermissionSetupView(model: model,
                onOpenSettings: { [weak self] in self?.beginSettingsGuidance() },
                onDrag: { [weak self] dragging in self?.setDragging(dragging) },
                onClose: { [weak self] in self?.close() })
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.level = .floating
        window?.orderFrontRegardless()
        startPolling()
    }

    func suspend() {
        suspended = true
        isDragging = false; window?.ignoresMouseEvents = false
        endSettingsGuidance()
        polling?.cancel(); polling = nil
        window?.orderOut(nil)
    }

    func resume() {
        suspended = false
        refresh()
        if let window { window.orderFrontRegardless(); startPolling() }
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let delay: Duration = self?.flowStartedAt == nil ? .seconds(1) : .milliseconds(150)
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !self.suspended else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastPermissionCheck >= 1 {
                    self.lastPermissionCheck = now
                    self.refresh()
                }
                self.updateSettingsPlacement()
            }
        }
    }

    private func close() { window?.close() }

    private func beginSettingsGuidance() {
        model.requestAccess()
        guard model.guidingInSettings else { return }
        flowStartedAt = ProcessInfo.processInfo.systemUptime; lastSettingsFrameAt = nil
        updateSettingsPlacement()
    }

    private func endSettingsGuidance() {
        flowStartedAt = nil; lastSettingsFrameAt = nil
        model.endGuidance()
    }

    private func setDragging(_ dragging: Bool) {
        isDragging = dragging
        window?.ignoresMouseEvents = dragging
        if !dragging { refresh(); updateSettingsPlacement() }
    }

    private func updateSettingsPlacement() {
        guard !suspended, !isDragging, let started = flowStartedAt, let window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let frame = PermissionSettingsWindow.frame() else {
            if let seen = lastSettingsFrameAt, now - seen > 1.2 { close() }
            else if lastSettingsFrameAt == nil, now - started > 10 { endSettingsGuidance() }
            return
        }
        lastSettingsFrameAt = now
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == PermissionSettingsWindow.bundleIdentifier || front?.processIdentifier == getpid() else {
            if window.isVisible { window.orderOut(nil) }
            return
        }
        guard let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(frame).size.area < $1.frame.intersection(frame).size.area
        }) else { return }
        let placement = PermissionSettingsWindow.placement(size: window.frame.size, beside: frame, visibleFrame: screen.visibleFrame)
        if window.frame != placement { window.setFrame(placement, display: true) }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        model.refresh()
        dismissedRequirement = model.status != .granted
        isDragging = false; closing.ignoresMouseEvents = false
        endSettingsGuidance()
        polling?.cancel(); polling = nil
        window = nil
    }

    deinit {
        polling?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

private extension CGSize {
    var area: CGFloat { width.isFinite && height.isFinite && width > 0 && height > 0 ? width * height : 0 }
}
