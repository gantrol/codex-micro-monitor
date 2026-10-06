import Foundation

/// Service authority and its last confirmed account are separate. A transport
/// outage revokes authority without pretending the user changed accounts.
struct ServiceConnectionState {
    struct Context: Equatable {
        let id: String?
        let scope: String?
    }

    private(set) var active: Context?
    private(set) var lastConfirmed: Context?
    private(set) var revision = 0
    var isConnected: Bool { active != nil }

    /// Returns true only when a successful response proves a context change.
    mutating func connect(id: String?, scope: String?) -> Bool {
        let next = Context(id: id, scope: scope)
        let changed = lastConfirmed.map { $0 != next } ?? false
        if active != next { revision += 1 }
        active = next
        lastConfirmed = next
        return changed
    }

    mutating func disconnect() {
        if active != nil { revision += 1 }
        active = nil
    }

    mutating func reset() {
        revision += 1
        active = nil
        lastConfirmed = nil
    }
}
