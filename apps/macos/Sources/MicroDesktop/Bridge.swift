import AppKit
import MicroCore
import MicroShared

@objc(MicroDesktopBridge) public final class MicroDesktopBridge: NSObject, DesktopServices, NSMenuDelegate {
    private let client = CodexClient()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var status: NSStatusItem?
    private weak var window: NSWindow?
    private var event: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var scale = 0.75
    private var floating = true
    private var configured = false
    public required override init() { super.init() }

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
        done.wait()
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
            guard let self, note.object as? NSWindow === self.window else { return }
            self.window?.saveFrame(usingName: "MicroUIKitPanel")
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.resize() })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.event?("sleep") })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.window?.isVisible == true { self?.event?("show") }
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
        return true
    }
    private func resize() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let s = min(scale, area.width / 590, area.height / 610)
        let size = NSSize(width: 590 * s, height: 610 * s)
        let origin = NSPoint(x: max(area.minX, min(window.frame.minX, area.maxX - size.width)),
                             y: max(area.minY, min(window.frame.maxY - size.height, area.maxY - size.height)))
        window.level = floating ? .floating : .normal
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
    public func showWindow() { resize(); window?.orderFrontRegardless(); event?("show") }
    public func hideWindow() { window?.orderOut(nil); event?("hide") }
    public func centerWindow() { window?.center(); resize() }
    public func dragWindow() { if let event = NSApp.currentEvent { window?.performDrag(with: event) } }
    public func showMenu() { status?.button?.performClick(nil) }
    public func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
    private func tr(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ command: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: command == "quit" ? "q" : "")
            item.target = self; item.representedObject = command; menu.addItem(item); return item
        }
        _ = add(tr(window?.isVisible == true ? "hide" : "show"), "toggle")
        _ = add(tr("refresh"), "refresh")
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
        case "center": centerWindow()
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
