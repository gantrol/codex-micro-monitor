// Adapted from PermissionFlow v2.11.3 AppDropArea.swift (MIT).
// Copyright (c) 2026 小弟调调. See ThirdParty/PermissionFlow/LICENSE.
import AppKit

/// A real .app file drag, not an image or text-only imitation of the app.
@MainActor final class PermissionAppDragView: NSView, NSDraggingSource {
    let applicationURL: URL
    var onDragStateChange: ((Bool) -> Void)?
    var allowsDragging = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    private var mouseDownPoint: NSPoint?
    private var hasBegunDragging = false
    private let appIcon: NSImage

    init(applicationURL: URL) {
        self.applicationURL = applicationURL.standardizedFileURL
        appIcon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        super.init(frame: .zero)
        toolTip = applicationURL.path
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(applicationURL.deletingPathExtension().lastPathComponent)
        setAccessibilityHelp(Bundle.main.localizedString(forKey: "permissionDragHint", value: nil, table: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 88) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if allowsDragging { addCursorRect(bounds, cursor: .openHand) } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.white.setFill(); outline.fill()
        NSColor(calibratedWhite: 0.84, alpha: 1).setStroke(); outline.lineWidth = 1; outline.stroke()
        appIcon.draw(in: NSRect(x: 14, y: bounds.midY - 26, width: 52, height: 52))
        let name = applicationURL.deletingPathExtension().lastPathComponent
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (name as NSString).draw(in: NSRect(x: 80, y: bounds.midY, width: bounds.width - 92, height: 22),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        let key = allowsDragging ? "permissionDragLabel" : "permissionGranted"
        (Bundle.main.localizedString(forKey: key, value: nil, table: nil) as NSString)
            .draw(in: NSRect(x: 80, y: bounds.midY - 21, width: bounds.width - 92, height: 20),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = allowsDragging ? convert(event.locationInWindow, from: nil) : nil
        hasBegunDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard allowsDragging, !hasBegunDragging, let origin = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 4,
              applicationURL.isFileURL, applicationURL.pathExtension.lowercased() == "app",
              (try? applicationURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        hasBegunDragging = true
        // NSURL supplies AppKit's supported file URL representations. A custom
        // legacy NSFilenamesPboardType writer is rejected as an invalid UTI.
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(NSRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56), contents: appIcon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil; hasBegunDragging = false }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onDragStateChange?(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownPoint = nil; hasBegunDragging = false
        // Drop acceptance is not permission evidence. The model rechecks TCC.
        onDragStateChange?(false)
    }
}
