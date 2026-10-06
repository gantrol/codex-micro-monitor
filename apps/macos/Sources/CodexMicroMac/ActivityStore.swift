import Foundation
#if canImport(MicroShared)
import MicroShared
#endif

/// UI-side activity cache. Revisions belong to one account/connection context;
/// no activity observation can change conversation identity or a native lease.
struct ActivityStore {
    private(set) var revision = -1
    private(set) var signals: [String: TaskSignal] = [:]
    private(set) var attention: [String: TaskAttention] = [:]
    private(set) var unreadEvidence: [String: [String: Any]] = [:]
    private(set) var liveSettings: [String: [String: Any]] = [:]
    private(set) var visibleCandidates: [String] = []
    private(set) var visibilityKnown = false
    private(set) var streamConnected = false
    private var confirmations: [String: Int] = [:]
    private var minimumRevision = -1

    mutating func reset() { self = Self() }

    /// Transient read failure does not erase a confirmed-write barrier.
    mutating func disconnect() {
        signals = [:]; attention = [:]; unreadEvidence = [:]; liveSettings = [:]
        visibleCandidates = []; visibilityKnown = false; streamConnected = false
    }

    @discardableResult
    mutating func apply(_ snapshot: [String: Any]) -> Bool {
        guard let incoming = snapshot["revision"] as? Int, incoming >= revision,
              incoming >= minimumRevision else { return false }
        revision = incoming
        signals = (snapshot["signals"] as? [String: String] ?? [:]).compactMapValues(TaskSignal.init(rawValue:))
        attention = (snapshot["attention"] as? [String: String] ?? [:]).compactMapValues(TaskAttention.init(rawValue:))
        unreadEvidence = snapshot["unreadEvidence"] as? [String: [String: Any]] ?? [:]
        liveSettings = snapshot["settings"] as? [String: [String: Any]] ?? [:]
        visibleCandidates = snapshot["visibleContexts"] as? [String] ?? []
        visibilityKnown = snapshot["visibilityKnown"] as? Bool ?? false
        streamConnected = snapshot["streamConnected"] as? Bool ?? false
        confirmations = confirmations.filter { id, receipt in
            if receipt >= 0 { return incoming < receipt }
            // Compatibility with an older bridge: a matching observation
            // acknowledges the confirmation; unrelated revisions do not.
            return signals[id] != .unread && unreadEvidence[id]?["value"] as? Bool != true
        }
        return true
    }

    mutating func confirmUnread(_ id: String, receipt: [String: Any], context: String?) {
        let acceptedRevision = receipt["contextID"] as? String == context ? receipt["activityRevision"] as? Int : nil
        if let acceptedRevision { minimumRevision = max(minimumRevision, acceptedRevision) }
        confirmations[id] = acceptedRevision ?? -1
    }

    mutating func remove(_ id: String) {
        signals[id] = nil; attention[id] = nil; unreadEvidence[id] = nil
        liveSettings[id] = nil; confirmations[id] = nil
        visibleCandidates.removeAll { $0 == id }
    }

    func signal(for id: String, fallback: TaskSignal) -> TaskSignal {
        let raw = signals[id] ?? fallback
        if confirmations[id] != nil, [.idle, .unknown, .unread].contains(raw) { return .unread }
        return raw
    }

    func attention(for id: String, fallback: TaskAttention) -> TaskAttention {
        let raw = attention[id] ?? fallback
        return confirmations[id] != nil && raw != .waiting ? .unread : raw
    }
}

struct TaskLampPresentation {
    enum MaskReason: String { case notUnread, focusVerified, focusUnverified }
    let raw: TaskSignal
    let displayed: TaskSignal
    let unreadSource: String
    let unreadRevision: Int?
    let activityRevision: Int
    let maskReason: MaskReason
}
