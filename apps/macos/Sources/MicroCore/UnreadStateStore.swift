import Foundation

/// Serial-queue state machine for two independently delivered read-state
/// sources. A persistent transition is a barrier until IPC agrees with it.
/// An unrelated IPC revision is never treated as a new read/unread event.
struct UnreadStateStore {
    struct StreamStamp: Equatable {
        let generation: UUID
        let owner: String
        let revision: Int
    }
    private struct Entry {
        var value: Bool?
        var source = "unknown"
        var revision = 0
        var observedAt: TimeInterval = 0
        var barrier: Bool?
        var streamValue: Bool?
        var streamStamp: StreamStamp?
    }
    private var entries: [String: Entry] = [:]
    private var persistent: Set<String>?
    private var revision = 0

    mutating func reset() { self = Self() }

    mutating func retain(_ ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }

    mutating func observePersistent(_ unread: Set<String>?, ids: Set<String>, at now: TimeInterval) {
        defer { persistent = unread }
        guard let unread else { return }
        for id in ids {
            let value = unread.contains(id)
            guard persistent == nil || persistent?.contains(id) != value || entries[id] == nil else { continue }
            var entry = entries[id] ?? Entry()
            let transitioned = persistent.map { $0.contains(id) != value } ?? false
            let protect = transitioned || entry.barrier != nil
            assign(value, source: "persistent", at: now, to: &entry)
            // A first read/reconnect is a baseline, not evidence of a change.
            // Only observed transitions or a confirmed write create barriers.
            entry.barrier = protect ? value : nil
            entries[id] = entry
        }
    }

    mutating func confirmUnread(_ id: String, at now: TimeInterval) {
        var entry = entries[id] ?? Entry()
        assign(true, source: "confirmed", at: now, to: &entry)
        // Always establish a barrier, including when the previous IPC value
        // was true. Only post-confirmation evidence can acknowledge the write.
        entry.barrier = true
        entries[id] = entry
    }

    mutating func observeStream(_ id: String, value: Bool?, stamp: StreamStamp, at now: TimeInterval) {
        var entry = entries[id] ?? Entry()
        if let previous = entry.streamStamp, previous.generation == stamp.generation,
           previous.owner == stamp.owner, stamp.revision <= previous.revision { return }
        let sameOwner = entry.streamStamp.map { $0.generation == stamp.generation && $0.owner == stamp.owner } ?? false
        let changed = entry.streamValue != value
        entry.streamValue = value
        entry.streamStamp = stamp
        if let value {
            if let barrier = entry.barrier {
                if value == barrier {
                    entry.barrier = nil
                    assign(value, source: "desktop", at: now, to: &entry)
                }
            } else if changed || !sameOwner || entry.value == nil {
                assign(value, source: "desktop", at: now, to: &entry)
            }
        } else if entry.source == "desktop" {
            let fallback = persistent.map { $0.contains(id) }
            assign(fallback, source: fallback == nil ? "unknown" : "persistent", at: now, to: &entry)
        }
        entries[id] = entry
    }

    mutating func disconnect(_ id: String, at now: TimeInterval) {
        guard var entry = entries[id] else { return }
        entry.streamValue = nil; entry.streamStamp = nil
        if entry.barrier != nil {
            // Preserve real transition/confirmation evidence across reconnects.
        } else if let persistent {
            let value = persistent.contains(id)
            assign(value, source: "persistent", at: now, to: &entry)
        } else if entry.source != "confirmed" {
            assign(nil, source: "unknown", at: now, to: &entry)
        }
        entries[id] = entry
    }

    func value(for id: String) -> Bool? { entries[id]?.value }

    func evidence(for id: String) -> [String: Any] {
        guard let entry = entries[id] else { return ["source": "unknown"] }
        return ["value": entry.value as Any? ?? NSNull(), "source": entry.source,
                "revision": entry.revision, "observedAt": entry.observedAt,
                "streamRevision": entry.streamStamp?.revision as Any? ?? NSNull(),
                "streamGeneration": entry.streamStamp?.generation.uuidString as Any? ?? NSNull(),
                "awaitingAgreement": entry.barrier != nil]
    }

    private mutating func assign(_ value: Bool?, source: String, at now: TimeInterval, to entry: inout Entry) {
        revision += 1
        entry.value = value; entry.source = source; entry.revision = revision; entry.observedAt = now
    }
}
