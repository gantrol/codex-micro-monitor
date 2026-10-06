import Foundation

struct DialActions {
    let step: (Int) -> Void
    let end: (Bool) -> Void
    let tap: () -> Void
}

struct ModelChoice: Identifiable {
    let id: String
    let title: String
    let efforts: [String]
    let defaultEffort: String
    let supportsFast: Bool

    init?(_ raw: [String: Any]) {
        guard let id = raw["model"] as? String, !id.isEmpty, raw["hidden"] as? Bool != true else { return nil }
        self.id = id
        title = raw["displayName"] as? String ?? id
        efforts = (raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
        defaultEffort = raw["defaultReasoningEffort"] as? String ?? ""
        let tiers = raw["serviceTiers"] as? [[String: Any]] ?? []
        supportsFast = tiers.contains { ["fast", "priority"].contains($0["id"] as? String ?? "") }
            || (raw["additionalSpeedTiers"] as? [String] ?? []).contains("fast")
    }
}

struct ApprovalChoice: Identifiable {
    let id: String
    let method: String
    let details: [String: Any]
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, let method = raw["method"] as? String else { return nil }
        self.id = id; self.method = method
        details = raw["details"] as? [String: Any] ?? [:]
    }
    var text: String {
        // Include the actual request, not an inferred friendly description that
        // might omit a command argument, affected file or approval reason.
        guard let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return id }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ControlTarget {
    let threadID: String
    let title: String
    let version: Int
    let lifecycle: Int
    let settings: [String: Any]
    let turnID: String?
    var uiToken: String? = nil
    var contextSource: String = "selected"
    var isDraft: Bool { threadID == "draft" }
    var isNativeComposer: Bool { threadID == "native-composer" }
    var usesNativeSettings: Bool { isDraft || isNativeComposer }
    var fast: Bool { ["fast", "priority"].contains(settings["serviceTier"] as? String ?? "") }
}
