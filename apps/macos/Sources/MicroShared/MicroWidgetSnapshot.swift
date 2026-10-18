import Foundation
import CryptoKit

public struct MicroWidgetSnapshot: Codable, Equatable {
    public struct Meter: Codable, Equatable {
        public struct Window: Codable, Equatable {
            public let id: String
            public let label: String
            public let available: Bool
            public let remaining: Double?
            public init(id: String, label: String, available: Bool, remaining: Double?) {
                self.id = id; self.label = label; self.available = available; self.remaining = remaining
            }
        }
        public let windows: [Window]
        public let connected: Bool
        public let desktopConnected: Bool
        public let attention: Bool
        public init(windows: [Window], connected: Bool, desktopConnected: Bool, attention: Bool) {
            self.windows = windows; self.connected = connected
            self.desktopConnected = desktopConnected; self.attention = attention
        }
        public static let empty = Meter(windows: [], connected: false, desktopConnected: false, attention: false)
        public var label: String {
            windows.filter(\.available).map { window in
                let value = window.remaining.flatMap { $0.isFinite ? "\(Int(max(0, min(100, $0)).rounded()))%" : nil } ?? "—"
                return "\(window.label) \(value)"
            }.joined(separator: " · ")
        }
    }

    public struct Key: Codable, Equatable, Identifiable {
        public let slot: Int
        public let threadID: String?
        public let label: String
        public let signal: String
        public let selected: Bool
        public var id: Int { slot }

        public init(slot: Int, threadID: String?, label: String, signal: String, selected: Bool) {
            self.slot = slot; self.threadID = threadID; self.label = label
            self.signal = signal; self.selected = selected
        }
    }

    public static let kind = "MicroSecondScreen"
    public static let lifetime: TimeInterval = 15 * 60
    public static let cells = Array(0..<16).filter { ![12, 15].contains($0) }
    public let version: Int
    public let updatedAt: Date
    public let scope: String?
    public let connected: Bool
    public let keys: [Key]
    public let meter: Meter?
    public let artwork: Data

    public init(updatedAt: Date, scope: String?, connected: Bool, keys: [Key], meter: Meter = .empty, artwork: Data) {
        version = 2; self.updatedAt = updatedAt; self.scope = scope
        self.connected = connected; self.keys = keys; self.meter = meter; self.artwork = artwork
    }

    public func isFresh(at date: Date) -> Bool {
        version == 2 && connected && date >= updatedAt.addingTimeInterval(-60)
            && date < updatedAt.addingTimeInterval(Self.lifetime)
    }

    public static func scopeID(_ scope: String?) -> String? {
        scope.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    public static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MicroWidgetAppGroup") as? String,
              !group.hasPrefix("$"), group.split(separator: ".").first?.count == 10,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent("SecondScreen.json")
    }

    public static func read() -> Self? {
        guard let url = fileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000,
              let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == 2, snapshot.keys.count <= 14,
              Set(snapshot.keys.map(\.slot)).count == snapshot.keys.count,
              snapshot.keys.allSatisfy({ (0..<14).contains($0.slot) && ($0.threadID.map { UUID(uuidString: $0) != nil } ?? true) }) else { return nil }
        return snapshot
    }

    public static func url(threadID: String? = nil, scope: String? = nil, activateCodex: Bool = false) -> URL {
        var parts = URLComponents()
        parts.scheme = "codex-micro-monitor"; parts.host = "widget"
        parts.queryItems = []
        if let threadID, let scope {
            parts.queryItems = [URLQueryItem(name: "thread", value: threadID), URLQueryItem(name: "scope", value: scope)]
        }
        if activateCodex { parts.queryItems?.append(URLQueryItem(name: "action", value: "activateCodex")) }
        return parts.url!
    }
}
