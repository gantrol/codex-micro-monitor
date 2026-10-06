import Foundation

/// Read authority is independent of composer controls. This value never grants
/// permission to send, change settings, or use a server UUID for a mutation.
public struct NativeObservation {
    public enum Identity: Equatable {
        case unknown, thread(String), draft, client(String), unidentifiedComposer
    }
    public let identity: Identity
    public let token: String?
    public let route: String?
    public let readOnly: Bool
    public let appFocused: Bool

    public init(_ state: [String: Any]) {
        route = state["routeKey"] as? String
        readOnly = state["routeReadOnly"] as? Bool == true
        appFocused = state["appFocused"] as? Bool == true
        // Older adapters expose only targetToken. An explicitly null read
        // token from a current adapter must never revive that legacy fallback.
        let rawToken = state.keys.contains("observationToken") ? state["observationToken"] : state["targetToken"]
        token = (rawToken as? String).flatMap { $0.isEmpty ? nil : $0 }
        if state["routeAvailable"] as? Bool == true, state["draft"] as? Bool == true {
            identity = .draft
        } else if state["routeAvailable"] as? Bool == true, let id = state["threadId"] as? String,
                  let uuid = UUID(uuidString: id) {
            identity = .thread(uuid.uuidString.lowercased())
        } else if state["selectionKnown"] as? Bool == true, state["draft"] as? Bool != true,
                  state["threadId"] as? String == nil, let client = ClientThreadIdentity.fromRoute(route),
                  client == state["clientThreadId"] as? String, token != nil {
            identity = .client(client)
        } else if NativeComposerIdentity.settingsOnly(state), token != nil {
            identity = .unidentifiedComposer
        } else {
            identity = .unknown
        }
    }

    public var clientID: String? {
        if case .client(let id) = identity { return id }
        return nil
    }
    public var isComposerIdentity: Bool {
        if case .client = identity { return true }
        return identity == .unidentifiedComposer
    }
}
