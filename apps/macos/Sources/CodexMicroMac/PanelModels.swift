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
    let hasDraft:Bool
    let project: String
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        self.id = id
        let title = raw["title"] as? String ?? ""
        self.title = title.isEmpty ? tr("untitled") : String(title.prefix(160))
        let status=raw["status"] as? [String:Any] ?? [:]
        hasUnreadTurn=raw["hasUnreadTurn"] as? Bool ?? false
        hasDraft=raw["hasDraft"] as? Bool ?? false
        attention=(raw["attention"] as? String).flatMap(TaskAttention.init(rawValue:)) ?? TaskAttention.classify(status:status,question:raw["hasPendingQuestion"] as? Bool ?? false,unread:hasUnreadTurn)
        recencyAt=TaskAttention.recency(raw)
        signal=TaskSignal.classify(status:status,question:raw["hasPendingQuestion"] as? Bool ?? false,unread:hasUnreadTurn,errorCode:raw["errorCode"] as? String ?? status["errorCode"] as? String)
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
struct CreditBalance: Equatable {
    let unlimited: Bool
    let balance: Decimal
    var isExhausted: Bool { !unlimited && balance <= 0 }
    var displayText: String { unlimited ? "∞" : Self.formatCompact(balance) }

    static func parse(_ limits: [String: Any]) -> CreditBalance? {
        guard let rateLimits = limits["rateLimits"] as? [String: Any],
              let credits = rateLimits["credits"] as? [String: Any] else { return nil }
        if credits["unlimited"] as? Bool == true { return CreditBalance(unlimited: true, balance: 0) }
        guard credits["hasCredits"] as? Bool == true else { return nil }
        if let text = credits["balance"] as? String,
           let parsed = Decimal(string: text.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX")),
           !parsed.isNaN {
            return CreditBalance(unlimited: false, balance: parsed)
        }
        if let number = credits["balance"] as? NSNumber, !(number is Bool) {
            return CreditBalance(unlimited: false, balance: number.decimalValue)
        }
        return nil
    }

    static func formatCompact(_ value: Decimal) -> String {
        let clamped = max(0.0, NSDecimalNumber(decimal: value).doubleValue)
        let cents = Int((clamped * 100.0).rounded())
        if cents >= 100_000 {
            let thousands = Double(cents) / 100_000.0
            let formatted = thousands >= 100.0
                ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), thousands)
                : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), thousands).replacingOccurrences(of: ".0", with: "")
            return "\(formatted)k"
        }
        if cents % 100 == 0 { return "\(cents / 100)" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(cents) / 100.0)
    }
}
