import AppKit
import MicroCore

/// Application recovery is independent of accessibility, IPC and chat identity.
/// Reopening the existing app restores its windows without navigating a chat.
@MainActor enum CodexApplication {
    /// Launch Services callbacks are not task cancellation points. Own their
    /// continuation so cancellation and a missing callback cannot lock Micro.
    @MainActor final class OpenRequest {
        typealias Open = @MainActor (URL, @escaping @Sendable (NSRunningApplication?, Error?) -> Void) -> Void
        private let opener: Open
        private let timeoutDuration: Duration
        private var continuation: CheckedContinuation<NSRunningApplication, Error>?
        private var result: Result<NSRunningApplication, Error>?
        private var timeout: Task<Void, Never>?

        init(timeout: Duration = .seconds(6), open: @escaping Open = { url, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
        }) {
            opener = open
            timeoutDuration = timeout
        }

        func finish(_ result: Result<NSRunningApplication, Error>) {
            guard self.result == nil else { return }
            self.result = result
            timeout?.cancel(); timeout = nil
            continuation?.resume(with: result); continuation = nil
        }

        func open(_ url: URL) async throws -> NSRunningApplication {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await waitForApplication(url)
            } onCancel: {
                Task { @MainActor in self.finish(.failure(CancellationError())) }
            }
        }

        private func waitForApplication(_ url: URL) async throws -> NSRunningApplication {
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result); return }
                self.continuation = continuation
                timeout = Task { [weak self] in
                    guard let duration = self?.timeoutDuration else { return }
                    do { try await Task.sleep(for: duration) } catch { return }
                    self?.finish(.failure(CodexClientError.unavailable("Codex did not finish opening in time.")))
                }
                opener(url) { [weak self] app, error in
                    Task { @MainActor in
                        if let error { self?.finish(.failure(error)) }
                        else if let app { self?.finish(.success(app)) }
                        else { self?.finish(.failure(CodexClientError.outcomeUnknown)) }
                    }
                }
            }
        }
    }

    private static func hasVisibleWindow(_ pid: Int32) -> Bool {
        // Window-server metadata does not require Accessibility or capture any
        // screen pixels. Process activation alone does not prove window recovery.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.width > 0 && rect.height > 0
        }
    }

    static func activate() async throws -> [String: Any] {
        try Task.checkCancellation()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated }
        guard running.count <= 1 else {
            throw CodexClientError.unavailable("More than one Codex application is running.")
        }
        guard let url = running.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            throw CodexClientError.unavailable("The Codex desktop app is unavailable.")
        }
        let request = OpenRequest()
        let app = try await request.open(url)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            try Task.checkCancellation()
            if app.isActive, !app.isTerminated, hasVisibleWindow(app.processIdentifier) {
                return ["launch_requested": true, "activated": true, "window_visible": true, "submitted": false, "verified": true]
            }
            guard !app.isTerminated else { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw CodexClientError.outcomeUnknown
    }
}
