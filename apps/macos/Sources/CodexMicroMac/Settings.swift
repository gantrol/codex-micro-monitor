import Foundation
import Combine

struct QuickModelPreset: Codable, Equatable {
    var model: String
    var effort: String?
}

struct DialProfile: Codable, Equatable {
    // nil follows Codex. Do not infer the user's binding from Windows defaults.
    var encoderMode: String?
    var invertDirection = false
    var a = QuickModelPreset(model: "gpt-5.6-sol")
    var b = QuickModelPreset(model: "gpt-5.6-luna")
}

@MainActor final class Settings: ObservableObject {
    static let designWidth = 590.0
    static let designHeight = 610.0
    static let defaultScale = 0.75
    static let scales = [0.6, 0.75, 0.9, 1.0, 1.05]
    private let defaults: UserDefaults
    @Published private(set) var scale: Double
    @Published private(set) var floating: Bool
    @Published private(set) var dial: DialProfile

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: "scale")
        scale = saved.isFinite && (0.6...1.05).contains(saved) ? saved : Self.defaultScale
        floating = defaults.object(forKey: "floating") as? Bool ?? true
        dial = defaults.data(forKey: "dialProfile.v1").flatMap { try? JSONDecoder().decode(DialProfile.self, from: $0) } ?? DialProfile()
    }

    func setScale(_ value: Double) {
        guard value.isFinite else { return }
        scale = min(1.05, max(0.6, value))
        defaults.set(scale, forKey: "scale")
    }

    func toggleFloating() {
        floating.toggle()
        defaults.set(floating, forKey: "floating")
    }

    func setDial(_ profile: DialProfile) {
        guard profile.encoderMode == nil || ["reasoning", "composer-navigation", "conversation-scroll"].contains(profile.encoderMode!),
              !profile.a.model.isEmpty, !profile.b.model.isEmpty,
              let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: "dialProfile.v1")
        dial = profile
    }
}
