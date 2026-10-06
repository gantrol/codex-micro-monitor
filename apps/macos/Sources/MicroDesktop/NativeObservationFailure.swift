import Foundation

enum NativeObservationFailure: String, LocalizedError {
    case accessibilityRequired, applicationUnavailable, applicationAmbiguous, foregroundRequired
    case windowUnavailable, windowMinimized, windowChanged, treeIncomplete

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: return "Enable Codex Micro Monitor in System Settings → Privacy & Security → Accessibility."
        case .applicationUnavailable: return "The Codex desktop application is not running."
        case .applicationAmbiguous: return "A unique running Codex application was not found."
        case .foregroundRequired: return "Bring the target Codex window or Micro to the front."
        case .windowUnavailable: return "No current Codex window."
        case .windowMinimized: return "The current Codex window is minimized."
        case .windowChanged: return "The current Codex window changed during observation."
        case .treeIncomplete: return "The Codex accessibility tree is incomplete."
        }
    }
}
