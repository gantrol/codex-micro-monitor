import AppKit
import MicroCore
import MicroShared
import OSLog

@MainActor @objc(MicroDesktopBridge) public final class MicroDesktopBridge: NSObject, DesktopServices, NSMenuDelegate {
    private let client = DesktopBackend()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var status: NSStatusItem?
    private weak var window: NSWindow?
    private var event: ((String) -> Void)?
    private var scrollMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var scale = 0.75
    private var floating = true
    private var configured = false
    private var settingsVisible = false
    private var keypadFrame: NSRect?
    private var settingsFrame: NSRect?
    private var permissionSetup: PermissionSetupCoordinator?
    public required override init() {
        super.init()
        let logger = Logger(subsystem: "com.gantrol.codex-micro-monitor", category: "runtime-build")
        if let url = Bundle(for: Self.self).url(forResource: "BuildIdentity", withExtension: "json"),
           let data = try? Data(contentsOf: url), let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let source = identity["sourceSHA256"] as? String, let built = identity["builtAtUTC"] as? String {
            logger.notice("Runtime build: source=\(source,privacy:.public) built=\(built,privacy:.public) pid=\(getpid()) app=\(Bundle.main.bundleURL.path,privacy:.public)")
        } else {
            logger.warning("Runtime build identity is unavailable; pid=\(getpid())")
        }
    }
    deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }

    public func installScrollInput(_ input: @escaping (Double, Double, Double, Double, Bool, String) -> Bool) {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        // Local to Micro's window. Consume only events claimed by a visible dial,
        // so Catalyst cannot dispatch the same wheel movement a second time.
        scrollMonitor=NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) { [weak self] event in
            guard let self,let window=self.window,event.window === window,window.isVisible,
                  let content=window.contentView,content.bounds.width>0,content.bounds.height>0 else { return event }
            let point=content.convert(event.locationInWindow,from:nil)
            let x=(point.x-content.bounds.minX)/content.bounds.width
            let y=(point.y-content.bounds.minY)/content.bounds.height
            let phase:String
            if !event.momentumPhase.isEmpty { phase="momentum" }
            else if event.phase.contains(.cancelled) { phase="cancel" }
            else if event.phase.contains(.ended) { phase="end" }
            else if event.phase.contains(.began) || event.phase.contains(.mayBegin) { phase="begin" }
            else if event.phase.contains(.changed) || event.phase.contains(.stationary) { phase="change" }
            else { phase="wheel" }
            return input(x,content.isFlipped ? y : 1-y,event.scrollingDeltaX,event.scrollingDeltaY,event.hasPreciseScrollingDeltas,phase) ? nil : event
        }
    }

    public func execute(_ id: String, operation: String, arguments: Data, reply: @escaping (Data?, NSError?) -> Void) {
        // All entry calls are on the main thread. CodexClient serializes native I/O.
        tasks[id] = Task { @MainActor in
            defer { tasks[id] = nil }
            do {
                try Task.checkCancellation()
                guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
                    throw NSError(domain: "MicroBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid arguments"])
                }
                let result = try await client.execute(operation, arguments: args)
                if operation == "get_keypad_ui_state", result["accessibility"] as? Bool == false {
                    // Recheck the current process's trust; a late native result
                    // must not turn an already restored permission into denial.
                    permissionSetup?.refresh()
                }
                reply(try JSONSerialization.data(withJSONObject: result), nil)
            } catch {
                var code = 1
                if case CodexClientError.outcomeUnknown = error { code = 2 }
                if error is CancellationError { code = 3 }
                reply(nil, NSError(domain: "MicroBridge", code: code, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
            }
        }
    }
    public func cancel(_ id: String) { tasks[id]?.cancel() }
    public func close(_ reply: @escaping () -> Void) {
        tasks.values.forEach { $0.cancel() }
        Task { @MainActor in await client.close(); reply() }
    }
    public func runMCP() {
        let done = DispatchSemaphore(value: 0)
        Task.detached { await MCPServer().run(); done.signal() }
        // AppKit may marshal workspace/pasteboard work to the main run loop.
        // No Catalyst scene is created for the stdio process.
        while done.wait(timeout: .now()) != .success { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
    }
    public func install(_ event: @escaping (String) -> Void) {
        self.event = event
        guard status == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()
        item.button?.toolTip = "Codex Micro Monitor"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        status = item
        rebuildMenu(menu)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? NSWindow === self.window else { return }
                if !self.settingsVisible { self.window?.saveFrame(usingName: "MicroUIKitPanel") }
            }
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resize() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.openai.codex" || app?.processIdentifier == getpid() else { return }
                MainActor.assumeIsolated { self?.event?("observationChanged") }
            })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionSetup?.suspend(); self?.event?("sleep") }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.window?.isVisible == true { self?.permissionSetup?.resume(); self?.event?("show") }
            }
        })
    }
    public func configureWindow(_ title: String, scale: Double, floating: Bool) -> Bool {
        self.scale = scale; self.floating = floating
        // The scene supplies an explicit unique title. Never choose another app window.
        if window == nil { window = NSApp.windows.first { $0.title == title && !($0 is NSPanel) } }
        guard let window else { return false }
        if !configured {
            configured = true
            window.styleMask = [.borderless]
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if !window.setFrameUsingName("MicroUIKitPanel") { window.center() }
        }
        resize()
        if permissionSetup == nil {
            let setup = PermissionSetupCoordinator { [weak self] _ in self?.event?("observationChanged") }
            permissionSetup = setup
            setup.start()
        }
        return true
    }
    private func resize() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let s = min(scale, area.width / 590, area.height / 610)
        let size = settingsVisible ? NSSize(width: min(720, area.width), height: min(760, area.height)) : NSSize(width: 590 * s, height: 610 * s)
        let origin = NSPoint(x: max(area.minX, min(window.frame.minX, area.maxX - size.width)),
                             y: max(area.minY, min(window.frame.maxY - size.height, area.maxY - size.height)))
        window.level = floating ? .floating : .normal
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
    public func setSettingsVisible(_ visible: Bool) {
        guard settingsVisible != visible, let window else { return }
        if visible {
            keypadFrame = window.frame
            settingsVisible = true
            if let settingsFrame { window.setFrame(settingsFrame, display: false) }
            else {
                let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
                window.setFrame(NSRect(x:center.x-360, y:center.y-380, width:720, height:760), display:false)
            }
            resize()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            settingsFrame = window.frame
            settingsVisible = false
            if let keypadFrame { window.setFrame(keypadFrame, display:false) }
            resize()
        }
    }
    public func showWindow() { resize(); window?.orderFrontRegardless(); permissionSetup?.resume(); event?("show") }
    public func hideWindow() { permissionSetup?.suspend(); window?.orderOut(nil); event?("hide") }
    public func centerWindow() { window?.center(); resize() }
    public func dragWindow() { if let event = NSApp.currentEvent { window?.performDrag(with: event) } }
    public func showMenu() {
        guard let window,let content=window.contentView else { return }
        let menu=NSMenu();menu.delegate=self;rebuildMenu(menu)
        let point=content.convert(window.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil)
        menu.popUp(positioning:nil,at:point,in:content)
    }
    public func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
    private func tr(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ command: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: command == "quit" ? "q" : "")
            item.target = self; item.representedObject = command; menu.addItem(item); return item
        }
        _ = add(tr(window?.isVisible == true ? "hide" : "show"), "toggle")
        add(tr("settings"), "settings").keyEquivalent = ","
        _ = add(tr("refresh"), "refresh")
        _ = add(tr("permissionSetup"), "accessibility")
        menu.addItem(.separator())
        add(tr("floating"), "floating").state = floating ? .on : .off
        let sizeItem = add(tr("size"), "size"), sizes = NSMenu()
        for value in [0.6, 0.75, 0.9, 1.0, 1.05] {
            let item = NSMenuItem(title: "\(Int((value * 100).rounded()))%", action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = "scale:\(value)"
            item.state = abs(value - scale) < 0.001 ? .on : .off; sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        _ = add(tr("center"), "center")
        menu.addItem(.separator()); _ = add(tr("quit"), "quit")
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        switch command {
        case "toggle": window?.isVisible == true ? hideWindow() : showWindow()
        case "settings": showWindow(); event?("settings")
        case "center": centerWindow()
        case "accessibility": showWindow(); permissionSetup?.show()
        case "quit":
            event?("hide")
            close { NSApp.terminate(nil) }
        default: event?(command)
        }
    }
    private static func statusImage() -> NSImage {
        // A small-size template rendition of Micro's framed infinity brand.
        // No opaque white tile and no unrelated CODEX command-key glyph.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setStrokeColor(NSColor.black.cgColor); c.setLineWidth(1)
            c.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), cornerWidth: 3.2, cornerHeight: 3.2, transform: nil)); c.strokePath()
            c.setLineWidth(1.65); c.setLineCap(.round); c.setLineJoin(.round)
            c.move(to: CGPoint(x: 9, y: 9))
            c.addCurve(to: CGPoint(x: 5.9, y: 6.95), control1: CGPoint(x: 7.6, y: 7.8), control2: CGPoint(x: 6.6, y: 6.95))
            c.addCurve(to: CGPoint(x: 5.9, y: 11.05), control1: CGPoint(x: 3.8, y: 6.95), control2: CGPoint(x: 3.8, y: 11.05))
            c.addCurve(to: CGPoint(x: 12.1, y: 6.95), control1: CGPoint(x: 7.4, y: 11.05), control2: CGPoint(x: 10.6, y: 6.95))
            c.addCurve(to: CGPoint(x: 12.1, y: 11.05), control1: CGPoint(x: 14.2, y: 6.95), control2: CGPoint(x: 14.2, y: 11.05))
            c.addCurve(to: CGPoint(x: 9, y: 9), control1: CGPoint(x: 11.4, y: 11.05), control2: CGPoint(x: 10.4, y: 10.2)); c.strokePath()
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Codex Micro Monitor"; return image
    }
}
