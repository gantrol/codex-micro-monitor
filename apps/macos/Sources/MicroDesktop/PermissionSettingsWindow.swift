// Window-server geometry approach adapted from PermissionFlow v2.11.3 (MIT).
// Copyright (c) 2026 小弟调调. See ThirdParty/PermissionFlow/LICENSE.
import AppKit
import CoreGraphics

/// Only reads geometry for System Settings. No AX trust or screen capture is
/// needed to position the helper that is obtaining Accessibility permission.
@MainActor enum PermissionSettingsWindow {
    static let bundleIdentifier = "com.apple.systempreferences"

    static func frame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.activationPolicy != .prohibited }.map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
              }) else { return nil }
        return windows.compactMap { row -> NSRect? in
            guard let pid = row[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  row[kCGWindowLayer as String] as? Int == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw),
                  [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
                  bounds.width > 320, bounds.height > 240 else { return nil }
            return NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    static func placement(size: NSSize, beside target: NSRect, visibleFrame: NSRect) -> NSRect {
        let area = visibleFrame.insetBy(dx: 10, dy: 10), gap: CGFloat = 12
        let size = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let candidates = [
            NSRect(x: target.maxX + gap, y: target.maxY - size.height, width: size.width, height: size.height),
            NSRect(x: target.minX - size.width - gap, y: target.maxY - size.height, width: size.width, height: size.height),
            NSRect(x: target.maxX - size.width, y: target.minY - size.height - gap, width: size.width, height: size.height),
            NSRect(x: target.maxX - size.width, y: target.maxY + gap, width: size.width, height: size.height)
        ]
        if let fitting = candidates.first(where: area.contains) { return fitting }
        // On small displays, use the lower leading edge. During the actual
        // drag the helper is mouse-transparent, so it cannot block the list.
        return NSRect(x: min(max(target.minX + gap, area.minX), area.maxX - size.width),
                      y: min(max(target.minY + gap, area.minY), area.maxY - size.height), width: size.width, height: size.height)
    }
}
