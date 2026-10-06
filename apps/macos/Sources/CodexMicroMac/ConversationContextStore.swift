import Foundation
#if canImport(MicroShared)
import MicroShared
#endif

/// Owns identity arbitration only. Activity/following events are deliberately
/// absent from the input: they cannot establish a foreground control target.
struct ConversationContextStore {
    enum Source: String { case none, foreground, selected }
    enum Identity: Equatable {
        case unknown
        case thread(String)
        case draft
        case nativeComposer
    }
    enum Resolution {
        case retain, clear, thread(String), draft, nativeComposer
    }
    struct ClientBinding {
        let client: String
        let token: String
        let scope: String
        let context: String
        let row: ThreadRow
        let observedAt: TimeInterval
    }
    struct ObservedIdentity {
        enum Origin: String { case nativeRoute, readOnlyRoute, verifiedClientBinding, nativeComposer }
        let identity: Identity
        let origin: Origin
        let clientID: String?
        let observedAt: TimeInterval
    }
    struct NativeLease {
        let token: String
        let routeKey: String?
        let observedAt: TimeInterval
    }

    private(set) var identity: Identity = .unknown
    private(set) var explicitTargetID: String?
    private(set) var source: Source = .none
    private(set) var foreground: [String: Any] = [:]
    private(set) var observedAt: TimeInterval = -.infinity
    private(set) var clientBinding: ClientBinding?
    private(set) var retiredRoutes: Set<String>?
    private var manualSelectionAnchor: String?
    private var nativeAuthorityObserved = false

    var selectedID: String? {
        if let explicitTargetID { return explicitTargetID }
        if case .thread(let id) = identity { return id }
        return nil
    }
    var isDraft: Bool { identity == .draft && explicitTargetID == nil }
    var isNativeComposer: Bool { identity == .nativeComposer && explicitTargetID == nil }

    func isFresh(at now: TimeInterval) -> Bool {
        let age = now - observedAt
        return age >= 0 && age < 2
    }

    mutating func observe(_ value: [String: Any], at now: TimeInterval) {
        if NativeObservation(foreground).token != NativeObservation(value).token ||
            foreground["routeKey"] as? String != value["routeKey"] as? String {
            clientBinding = nil
        }
        foreground = value
        observedAt = value.isEmpty ? -.infinity : now
    }

    mutating func bind(_ value: ClientBinding?) { clientBinding = value }

    func observedIdentity(scope: String?, context: String?, at now: TimeInterval) -> ObservedIdentity? {
        guard isFresh(at: now), retiredRoutes == nil else { return nil }
        let origin: ObservedIdentity.Origin = foreground["routeReadOnly"] as? Bool == true ? .readOnlyRoute : .nativeRoute
        if foreground["routeAvailable"] as? Bool == true {
            if foreground["draft"] as? Bool == true {
                return .init(identity: .draft, origin: origin, clientID: nil, observedAt: observedAt)
            }
            if let id = foreground["threadId"] as? String, UUID(uuidString: id) != nil {
                return .init(identity: .thread(id), origin: origin, clientID: nil, observedAt: observedAt)
            }
        }
        if let binding = clientBinding, let row = verifiedClientRow(scope: scope, context: context, at: now) {
            return .init(identity: .thread(row.id), origin: .verifiedClientBinding,
                         clientID: binding.client, observedAt: binding.observedAt)
        }
        if NativeObservation(foreground).isComposerIdentity {
            return .init(identity: .nativeComposer, origin: .nativeComposer,
                         clientID: foreground["clientThreadId"] as? String, observedAt: observedAt)
        }
        return nil
    }

    func nativeLease(at now: TimeInterval) -> NativeLease? {
        guard isFresh(at: now), retiredRoutes == nil, foreground["available"] as? Bool == true,
              foreground["routeReadOnly"] as? Bool != true,
              let token = foreground["targetToken"] as? String, !token.isEmpty else { return nil }
        return .init(token: token, routeKey: foreground["routeKey"] as? String, observedAt: observedAt)
    }

    func verifiedClientRow(scope: String?, context: String?, at now: TimeInterval) -> ThreadRow? {
        guard source == .foreground, isNativeComposer, isFresh(at: now),
              NativeObservation(foreground).clientID != nil, let binding = clientBinding,
              binding.scope == scope, binding.context == context,
              binding.client == foreground["clientThreadId"] as? String,
              binding.token == NativeObservation(foreground).token else { return nil }
        let age = now - binding.observedAt
        return age >= 0 && age < 2 ? binding.row : nil
    }

    /// Display evidence and focus evidence are separate capabilities. A client
    /// binding can mask unread presentation, but never grants UUID write access.
    func focusVerifiedID(scope: String?, context: String?, at now: TimeInterval) -> String? {
        guard source == .foreground, isFresh(at: now), retiredRoutes == nil,
              foreground["appFocused"] as? Bool == true,
              foreground["available"] as? Bool == true,
              foreground["routeReadOnly"] as? Bool != true else { return nil }
        if let row = verifiedClientRow(scope: scope, context: context, at: now) { return row.id }
        guard foreground["selectionKnown"] as? Bool == true,
              foreground["routeAvailable"] as? Bool == true,
              let id = selectedID, foreground["threadId"] as? String == id,
              foreground["routeKey"] as? String == "thread:" + id else { return nil }
        return id
    }

    mutating func selectThread(_ id: String, source: Source, at now: TimeInterval) {
        if source == .selected {
            explicitTargetID = id
            manualSelectionAnchor = observedContextID(at: now)
            retiredRoutes = nil
        } else {
            explicitTargetID = nil
            manualSelectionAnchor = nil
            identity = .thread(id)
        }
        self.source = source
        clientBinding = nil
    }

    mutating func selectComposer(nativeOnly: Bool) {
        explicitTargetID = nil
        manualSelectionAnchor = nil
        identity = nativeOnly ? .nativeComposer : .draft
        source = .foreground
    }

    mutating func clearTarget() {
        identity = .unknown
        explicitTargetID = nil
        manualSelectionAnchor = nil
        clientBinding = nil
        source = .none
    }

    mutating func reset() { self = Self() }

    mutating func beginNavigation(additionalRetiredRoutes: Set<String>) {
        var retired = retiredRoutes ?? Self.routeIdentityKeys(foreground)
        if source != .selected, let id = selectedID { retired.insert("thread:" + id) }
        if retired.isEmpty, !nativeAuthorityObserved { retired.formUnion(additionalRetiredRoutes) }
        reset()
        retiredRoutes = retired
        nativeAuthorityObserved = true
    }

    mutating func resolve(at now: TimeInterval) -> Resolution {
        let fresh = isFresh(at: now)
        let known = fresh && (foreground["selectionKnown"] as? Bool == true ||
            foreground["routeAvailable"] as? Bool == true || NativeObservation(foreground).isComposerIdentity)
        if known { nativeAuthorityObserved = true }
        if let retired = retiredRoutes {
            let keys = Self.routeIdentityKeys(foreground)
            let draft = known && foreground["routeAvailable"] as? Bool == true && foreground["draft"] as? Bool == true
            let thread = foreground["routeAvailable"] as? Bool == true &&
                (foreground["threadId"] as? String).flatMap(UUID.init(uuidString:)) != nil
            let composer = NativeObservation(foreground).isComposerIdentity
            guard draft || known && (thread || composer) && !keys.isEmpty && retired.isDisjoint(with: keys) else { return .retain }
            retiredRoutes = nil
        }
        let observed = observedContextID(at: now)
        if source == .selected, observed != explicitTargetID, observed == manualSelectionAnchor { return .retain }
        if fresh, foreground["routeAvailable"] as? Bool == true {
            if foreground["draft"] as? Bool == true { return .draft }
            if let id = foreground["threadId"] as? String, UUID(uuidString: id) != nil { return .thread(id) }
        }
        if fresh, NativeObservation(foreground).isComposerIdentity { return .nativeComposer }
        return source != .selected || nativeAuthorityObserved ? .clear : .retain
    }

    private func observedContextID(at now: TimeInterval) -> String? {
        guard isFresh(at: now) else { return nil }
        if NativeObservation(foreground).isComposerIdentity, let token = NativeObservation(foreground).token { return "native:" + token }
        if let key = foreground["routeKey"] as? String, foreground["selectionKnown"] as? Bool == true {
            return key.hasPrefix("thread:") ? String(key.dropFirst(7)) : key
        }
        if foreground["routeAvailable"] as? Bool == true {
            if foreground["draft"] as? Bool == true { return "draft" }
            if let id = foreground["threadId"] as? String, UUID(uuidString: id) != nil { return id }
        }
        return nil
    }

    private static func routeIdentityKeys(_ observed: [String: Any]) -> Set<String> {
        var keys = Set<String>()
        if let key = observed["routeKey"] as? String { keys.insert(key) }
        if let id = observed["threadId"] as? String { keys.insert("thread:" + id) }
        if let id = observed["clientThreadId"] as? String { keys.insert("client:" + id) }
        return keys
    }
}
