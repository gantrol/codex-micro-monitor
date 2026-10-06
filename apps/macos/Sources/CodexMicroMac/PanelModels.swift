import Foundation
#if canImport(MicroShared)
import MicroShared
#endif

// Visual precedence is shared by catalog, exact-owner and stream observations.
typealias TaskSignal=TaskLampSignal

struct ThreadRow: Identifiable {
    let id: String
    let title: String
    let signal: TaskSignal
    let attention:TaskAttention
    let recencyAt:Double
    let hasUnreadTurn:Bool
    let project: String
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        self.id = id
        let title = raw["title"] as? String ?? ""
        self.title = title.isEmpty ? tr("untitled") : String(title.prefix(160))
        let status=raw["status"] as? [String:Any] ?? [:]
        hasUnreadTurn=raw["hasUnreadTurn"] as? Bool ?? false
        attention=(raw["attention"] as? String).flatMap(TaskAttention.init(rawValue:)) ?? TaskAttention.classify(status:status,question:raw["hasPendingQuestion"] as? Bool ?? false,unread:hasUnreadTurn)
        recencyAt=TaskAttention.recency(raw)
        signal=TaskSignal.classify(status:status,question:raw["hasPendingQuestion"] as? Bool ?? false,unread:hasUnreadTurn)
        let cwd = raw["cwd"] as? String ?? ""
        project = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
    }
    var label: String { project.isEmpty ? title : "\(project) › \(title)" }
}
struct UsageWindow: Identifiable {
    let id: String
    let label: String
    let available: Bool
    let remaining: Double?
    let reset: Date?
    var text: String { remaining.map { "\(Int($0.rounded()))%" } ?? "—" }
}
