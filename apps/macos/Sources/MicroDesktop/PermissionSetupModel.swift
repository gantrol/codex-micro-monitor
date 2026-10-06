import AppKit
import ApplicationServices
import Combine
import OSLog
import SystemSettingsKit

/// Permission evidence is independent of the Codex connection and roster.
/// Opening System Settings never counts as granting access.
@MainActor final class PermissionSetupModel: ObservableObject {
    enum Status: Equatable { case unchecked, required, granted }
    @Published private(set) var status = Status.unchecked
    @Published private(set) var settingsUnavailable = false
    @Published private(set) var guidingInSettings = false
    @Published private(set) var needsRepair = false
    let applicationURL: URL
    private let readTrust: @MainActor () -> Bool
    private let requestTrust: @MainActor () -> Void
    private let openSettings: @MainActor () -> Bool
    private let revealApplication: @MainActor (URL) -> Void
    var trustChanged: (@MainActor (Bool) -> Void)?
    private static let logger = Logger(subsystem: "com.gantrol.codex-micro-monitor", category: "permission-setup")

    init(applicationURL: URL = Bundle.main.bundleURL,
         readTrust: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         requestTrust: @escaping @MainActor () -> Void = {
             _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
         },
         openSettings: @escaping @MainActor () -> Bool = {
             SystemSettings.open(paneIdentifier: "com.apple.preference.security", anchor: "Privacy_Accessibility")
         },
         revealApplication: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.applicationURL = applicationURL
        self.readTrust = readTrust
        self.requestTrust = requestTrust
        self.openSettings = openSettings
        self.revealApplication = revealApplication
    }

    func refresh() {
        let next: Status = readTrust() ? .granted : .required
        if next != status {
            status = next
            logStatus(action: "trust-changed")
            trustChanged?(next == .granted)
        }
        if next == .granted {
            if settingsUnavailable { settingsUnavailable = false }
            if needsRepair { needsRepair = false }
        }
    }

    func checkAccess() {
        refresh()
        needsRepair = status == .required
        logStatus(action: "manual-check")
    }

    private func logStatus(action: String) {
        Self.logger.notice("Permission \(action, privacy: .public): trusted=\(self.status == .granted, privacy: .public), pid=\(getpid()), app=\(self.applicationURL.path, privacy: .public)")
    }

    func requestAccess() {
        refresh()
        guard status == .required else { return }
        requestTrust()
        settingsUnavailable = !openSettings()
        if !settingsUnavailable { guidingInSettings = true }
        refresh()
    }

    func endGuidance() { guidingInSettings = false }
    func reveal() { revealApplication(applicationURL) }
}
