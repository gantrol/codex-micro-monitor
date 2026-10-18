import UIKit
import WidgetKit
import OSLog

@MainActor final class WidgetPublisher {
    private static let logger = Logger(subsystem: "com.gantrol.codex-micro-monitor", category: "widget")
    private var latest: MicroViewState?
    private var timer: Timer?
    private var last: MicroWidgetSnapshot?
    private var lastReload = Date.distantPast
    private var reloadPending = false
    private let snapshotURL = MicroWidgetSnapshot.fileURL
    var available: Bool { snapshotURL != nil }

    func update(_ state: MicroViewState) {
        latest = state
        guard available else { return }
        if timer == nil {
            flush()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
        // Clear the previous account's snapshot immediately, even during a burst of updates.
        if last?.scope != MicroWidgetSnapshot.scopeID(state.rosterScope) || last?.connected != state.connected { flush() }
    }

    deinit { timer?.invalidate() }

    private func flush() {
        guard let state = latest, let url = snapshotURL else { return }
        let now = Date(), scope = MicroWidgetSnapshot.scopeID(state.rosterScope)
        let keys = state.tasks.enumerated().map { index, task in
            let row = state.connected ? task.row.flatMap { row in state.knownThreads.contains(where: { $0.id == row.id }) ? row : nil } : nil
            return MicroWidgetSnapshot.Key(slot: index, threadID: row?.id,
                label: row == nil ? tr("emptySlot") : task.label,
                signal: row.flatMap { state.lamps[$0.id]?.displayed.rawValue } ?? "unknown",
                selected: row != nil && row?.id == state.displayedThreadID)
        }
        let meter = MicroWidgetSnapshot.Meter(windows: state.connected ? state.usageWindows.map {
            .init(id: $0.id, label: $0.label, available: $0.available, remaining: $0.remaining)
        } : [], connected: state.connected, desktopConnected: state.desktopConnected,
            attention: state.controlError != nil || state.needsControlRefresh)
        let changed = last?.keys != keys || last?.scope != scope || last?.connected != state.connected || last?.meter != meter
        if changed || now.timeIntervalSince(last?.updatedAt ?? .distantPast) >= 60 {
            do {
                let artwork: Data
                if !changed, let cached = last?.artwork { artwork = cached }
                else { artwork = try WidgetArtwork.png(keys: keys, meter: meter) }
                let snapshot = MicroWidgetSnapshot(updatedAt: now, scope: scope, connected: state.connected, keys: keys, meter: meter, artwork: artwork)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                last = snapshot
                reloadPending = reloadPending || changed
            } catch { Self.logger.error("Snapshot publication failed: \(error.localizedDescription, privacy: .private)") }
        }
        if reloadPending && now.timeIntervalSince(lastReload) >= 30 {
            WidgetCenter.shared.reloadTimelines(ofKind: MicroWidgetSnapshot.kind)
            lastReload = now; reloadPending = false
        }
    }
}

@MainActor enum WidgetArtwork {
    static func png(keys: [MicroWidgetSnapshot.Key], meter: MicroWidgetSnapshot.Meter = .empty) throws -> Data {
        let scale: CGFloat = 1.5
        let image = Paint.image(CGSize(width: 590, height: 610), scale: scale) { c in
            let shell = ShellView(frame: Paint.rect(0, 0, 590, 610))
            shell.transparentPanel = true
            shell.contentScaleFactor = scale; shell.draw(shell.bounds)
            let lights = (0..<14).map { slot -> LightState in
                let key = keys.first { $0.slot == slot }
                return LightState(signal: key.flatMap { TaskSignal(rawValue: $0.signal) } ?? .unknown, selected: key?.selected ?? false)
            }
            // Match the main panel's ordering: all outer halos, all inner halos, then keycaps.
            for near in [false, true] {
                for (slot, cell) in MicroWidgetSnapshot.cells.enumerated() {
                    let rect = box(cell)
                    KeyArt.halo(lights[slot], near: near, scale: scale).draw(in: rect)
                }
            }
            for (slot, cell) in MicroWidgetSnapshot.cells.enumerated() {
                key(c, cell: cell, light: lights[slot], task: true, scale: scale)
            }
            let neutral = LightState(signal: .unknown, selected: false)
            key(c, cell: 15, light: neutral, task: false, scale: scale)
            // Only paint the quota face. WidgetKit owns the refresh hit target;
            // no hover, dial gesture, or model-setting action is attached.
            c.saveGState(); c.translateBy(x: 88, y: 416)
            let quota = HardwareControl(.quota)
            quota.bounds = Paint.rect(0, 0, 96, 96); quota.contentScaleFactor = scale
            quota.usage = meter.windows.map { UsageWindow(id: $0.id, label: $0.label, available: $0.available, remaining: $0.remaining, reset: nil) }
            quota.connected = meter.connected; quota.desktopConnected = meter.desktopConnected
            quota.controlAttention = meter.attention
            quota.draw(quota.bounds)
            c.restoreGState()
            let side = KeycapGlyph.side(at: 1, name: "CODEX")
            Paint.glyph(c, "CODEX", in: Paint.rect(454-side/2, 463.25-side/2, side, side))
            Paint.shape(c, Paint.rect(273.5, 63.5, 7, 7), 4, color: 0x55718592)
            Paint.shape(c, Paint.rect(303, 63.5, 20, 7), 4, color: 0xFF7185EA)
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private static func box(_ cell: Int) -> CGRect {
        Paint.rect(88 + CGFloat(cell % 4)*106 - KeyArt.pad, 98 + CGFloat(cell / 4)*106 - KeyArt.pad,
                   96 + KeyArt.pad*2, 96 + KeyArt.pad*2)
    }

    private static func key(_ c: CGContext, cell: Int, light: LightState, task: Bool, scale: CGFloat) {
        let rect = box(cell)
        KeyArt.far(task: task, white: light.neutral, width: 96, scale: scale).draw(in: rect)
        if task { KeyArt.seam(light, scale: scale).draw(in: rect) }
        else { Paint.shape(c, Paint.rect(rect.minX+KeyArt.pad+0.5, rect.minY+KeyArt.pad+2, 95, 93.5), 14, color: 0xB8ADB4B0) }
        KeyArt.cap(task: task, width: 96, light: light, hover: false, scale: scale).draw(in: rect)
    }

    static func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png(keys: []).write(to: directory.appendingPathComponent("WidgetNeutral.png"), options: .atomic)
        let signals = ["idle", "running", "unread", "waiting", "error", "unknown", "idle", "question", "unread", "running", "unread", "unknown", "running", "idle"]
        let keys = signals.enumerated().map { MicroWidgetSnapshot.Key(slot: $0.offset, threadID: nil, label: "", signal: $0.element, selected: $0.offset == 1) }
        let meter = MicroWidgetSnapshot.Meter(windows: [
            .init(id: "primary", label: "5h", available: true, remaining: 77),
            .init(id: "secondary", label: "7d", available: true, remaining: 62)
        ], connected: true, desktopConnected: true, attention: false)
        try png(keys: keys, meter: meter).write(to: directory.appendingPathComponent("WidgetPreview.png"), options: .atomic)
    }
}
