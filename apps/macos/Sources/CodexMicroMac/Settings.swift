import Foundation
#if canImport(MicroShared)
import MicroShared
#endif
import Combine
import CoreGraphics

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

// Keep imported bindings intact until the user deliberately picks a new keycap.
struct KeyOverride: Codable, Equatable {
    var icon: String
    var actionData: Data?
    var action: [String: Any]? {
        actionData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    init(icon: String, action: [String: Any]?) {
        self.icon = icon
        actionData = action.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
    }
    mutating func selectIcon(_ icon: String) {
        guard self.icon != icon else { return }
        self = KeyOverride(icon: icon, action: KeySlots.defaultAction(icon))
    }
}

struct LayoutPreferences: Codable, Equatable {
    var separateMicrophoneKeys: Bool?
    var agentSource = "recent"
    var singleTapAgentKeys = true
    var keys: [String: KeyOverride] = [:]
    // Optional preserves decoding of existing layoutProfile.v1 preferences.
    var taskMappings: [String:[String:String]]?
    var taskCommands: [String:[String:String]]?
    func taskMap(scope:String?) -> [String:String] {scope.flatMap {taskMappings?[$0]} ?? [:]}
    func taskCommandMap(scope:String?) -> [String:String] {scope.flatMap {taskCommands?[$0]} ?? [:]}
}

enum TaskSlots {
    static let count=14
    static let ids=(0..<count).map {String(format:"AG%02d",$0)}
    static func validScope(_ scope:String) -> Bool {scope.count == 64 && scope.allSatisfy {"0123456789abcdef".contains($0)}}
    static func valid(_ maps:[String:[String:String]]?) -> Bool {
        guard let maps else {return true}
        return maps.count <= 64 && maps.allSatisfy {scope,map in
            validScope(scope) && map.count <= count && map.allSatisfy {ids.contains($0.key) && UUID(uuidString:$0.value) != nil}
        }
    }
    static func validCommands(_ maps:[String:[String:String]]?) -> Bool {
        guard let maps else {return true}
        return maps.count <= 64 && maps.allSatisfy {scope,map in
            validScope(scope) && map.count <= count && map.allSatisfy {ids.contains($0.key) && KeySlots.supportedCommands.contains($0.value)}
        }
    }
    static func unambiguous(_ layout:LayoutPreferences)->Bool {
        (layout.taskCommands ?? [:]).allSatisfy {scope,map in
            Set(map.keys).isDisjoint(with:Set(layout.taskMap(scope:scope).keys))
        }
    }
}

enum KeySlots {
    static let recentCommands=(1...6).map {"recentThread"+String($0)}
    static func recentIndex(_ command:String)->Int? {recentCommands.firstIndex(of:command)}
    static let supportedCommands: Set<String> = Set(["composer.submit", "composer.toggleFastMode", "composer.togglePlanMode",
        "approval.approve", "approval.decline", "forkThread", "newTask", "newThread", "toggleReviewTab", "openReviewTab", "review",
        "turn.cancel", "dictation.pushToTalk", "composer.dictation", "composer.sketch", "composer.increaseReasoningEffort",
        "composer.decreaseReasoningEffort", "toggleSidebar", "navigateBack", "navigateForward", "developers.openai.com", "openFolder", "settings", "openSkills",
        "toggleThreadPin", "copyConversationMarkdown", "archiveThread", "toggleTerminal", "openBrowserTab", "manageTasks", "feedback", "openSideChat", "composer.addFiles", "composer.addPhotos", "git.mergePullRequest", "git.commit", "git.createBranch", "git.createPullRequest", "git.createDraftPullRequest", "environmentAction1"]).union(recentCommands)
    static let aliases = ["FAST":"ACT06", "APPR":"ACT07", "REJ":"ACT08", "SPLIT":"ACT09",
                          "MIC":"ACT10_ACT11", "MIC1":"ACT10", "MIC2":"ACT11", "CODEX":"ACT12"]
    static let defaults = ["ACT06":"FAST", "ACT07":"APPR", "ACT08":"REJ", "ACT09":"SPLIT",
                           "ACT10_ACT11":"MIC", "ACT10":"MIC1", "ACT11":"EMPT1", "ACT12":"CODEX"]
    static let commands = ["FAST":"composer.toggleFastMode", "APPR":"approval.approve", "REJ":"approval.decline",
        "SPLIT":"forkThread", "MIC":"dictation.pushToTalk", "MIC1":"dictation.pushToTalk", "CODEX":"composer.submit",
        "NEW":"newTask", "DIFF":"toggleReviewTab", "SKETCH":"composer.sketch",
        "MIND+":"composer.increaseReasoningEffort", "MIND-":"composer.decreaseReasoningEffort",
        "BUG":"feedback", "OAI":"developers.openai.com", "TERM":"toggleTerminal",
        "DWN":"copyConversationMarkdown", "DEL":"archiveThread", "NAV":"openBrowserTab",
        "MAGIC":"toggleThreadPin", "PLAY":"environmentAction1", "GIT":"git.commit",
        "BRCH":"git.createDraftPullRequest", "BRANCH":"git.createBranch", "MRG":"git.mergePullRequest",
        "PR":"git.createPullRequest", "PAINT":"composer.addPhotos", "LAB":"settings", "SETUP":"settings",
        "PARTY":"openSideChat", "TIME":"manageTasks", "FOLD":"openFolder", "UPL":"composer.addFiles", "APPS":"openSkills"]
    static let emptyIcons=(1...5).map {"EMPT"+String($0)}
    static let iconIDs:[String] = {
        let primary=["FAST","APPR","REJ","SPLIT","MIC","MIC1","CODEX","SKETCH","MIND+","MIND-","EMPT1"]
        let all=Set(commands.keys).union(emptyIcons).union(ComposerTextPreset.allCases.map(\.rawValue))
        return primary+all.subtracting(primary).sorted()
    }()
    static func id(_ key: String) -> String { aliases[key] ?? key }
    static func defaultAction(_ icon: String) -> [String: Any]? {
        if let preset=ComposerTextPreset(rawValue:icon) {return ["type":"composer-text","text":preset.text]}
        return commands[icon].map { ["type":"command", "commandId":$0] }
    }
    static func actionLabel(_ action: [String:Any]?) -> String {
        guard let action else { return tr("emptySlot") }
        if action["type"] as? String == "composer-text",let preset=ComposerTextPreset.matching(action["text"] as? String) {return tr("writeToComposer")+" "+preset.text}
        if action["type"] as? String == "skill" { return "$" + (action["skillName"] as? String ?? "") }
        let command = action["commandId"] as? String ?? ""
        if let index=recentIndex(command) {return String(format:tr("recentTaskNumber"),index+1)}
        let labels = ["composer.submit":"submit", "composer.toggleFastMode":"fast", "composer.togglePlanMode":"plan",
            "approval.approve":"approve", "approval.decline":"decline", "forkThread":"fork", "newTask":"newDraft", "newThread":"newDraft",
            "toggleReviewTab":"review", "openReviewTab":"review", "review":"review", "turn.cancel":"stop",
            "dictation.pushToTalk":"voice", "composer.dictation":"voice", "composer.sketch":"sketch",
            "composer.increaseReasoningEffort":"moreReasoning", "composer.decreaseReasoningEffort":"lessReasoning",
            "toggleSidebar":"sidebar", "navigateBack":"back", "navigateForward":"forward",
            "feedback":"feedback", "developers.openai.com":"developers", "toggleTerminal":"terminal",
            "copyConversationMarkdown":"copyConversation", "archiveThread":"archiveChat", "openBrowserTab":"browser",
            "toggleThreadPin":"pinChat", "environmentAction1":"environmentAction", "git.commit":"commit",
            "git.createDraftPullRequest":"draftPR", "git.createBranch":"createBranch", "git.mergePullRequest":"mergePR",
            "git.createPullRequest":"createPR", "composer.addPhotos":"addPhotos", "settings":"codexSettings",
            "openSideChat":"sideChat", "manageTasks":"manageTasks", "openFolder":"openFolder", "composer.addFiles":"addFiles", "openSkills":"skills"]
        return labels[command].map(tr) ?? (command.isEmpty ? tr("customAction") : command)
    }
    static func frames(separate: Bool) -> [(String, CGRect)] {
        var keys = [("FAST", CGRect(x:88,y:310,width:96,height:96)), ("APPR", CGRect(x:194,y:310,width:96,height:96)),
                    ("REJ", CGRect(x:300,y:310,width:96,height:96)), ("SPLIT", CGRect(x:406,y:310,width:96,height:96))]
        keys += separate ? [("MIC1", CGRect(x:194,y:416,width:96,height:96)), ("MIC2", CGRect(x:300,y:416,width:96,height:96))]
                         : [("MIC", CGRect(x:194,y:416,width:202,height:96))]
        keys.append(("CODEX", CGRect(x:406,y:416,width:96,height:96)))
        return keys
    }
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
    @Published private(set) var layout: LayoutPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var savedLayout=defaults.data(forKey:"layoutProfile.v1").flatMap {try? JSONDecoder().decode(LayoutPreferences.self,from:$0)} ?? LayoutPreferences()
        if !TaskSlots.valid(savedLayout.taskMappings) {savedLayout.taskMappings=nil}
        if !TaskSlots.validCommands(savedLayout.taskCommands) || !TaskSlots.unambiguous(savedLayout) {savedLayout.taskCommands=nil}
        layout=savedLayout
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

    func setLayout(_ value: LayoutPreferences) {
        guard ["recent", "priority", "custom", "pinned"].contains(value.agentSource),TaskSlots.valid(value.taskMappings),
              TaskSlots.validCommands(value.taskCommands),TaskSlots.unambiguous(value),
              value.keys.keys.allSatisfy({ KeySlots.defaults[$0] != nil }),
              let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: "layoutProfile.v1")
        layout = value
    }

    func saveKey(_ key: String, value: KeyOverride) {
        var next = layout; next.keys[KeySlots.id(key)] = value; setLayout(next)
    }

    func saveTask(_ slot:Int,thread:String?,scope:String) {
        guard TaskSlots.ids.indices.contains(slot),TaskSlots.validScope(scope),thread == nil || UUID(uuidString:thread!) != nil else {return}
        var next=layout,maps=next.taskMappings ?? [:],map=maps[scope] ?? [:]
        if let thread {map=map.filter {$0.value != thread}}
        map[TaskSlots.ids[slot]]=thread;maps[scope]=map;next.taskMappings=maps
        next.taskCommands?[scope]?[TaskSlots.ids[slot]]=nil
        setLayout(next)
    }

    func saveTaskCommand(_ slot:Int,command:String?,scope:String) {
        guard TaskSlots.ids.indices.contains(slot),TaskSlots.validScope(scope),command == nil || KeySlots.supportedCommands.contains(command!) else {return}
        var next=layout,maps=next.taskCommands ?? [:],map=maps[scope] ?? [:]
        map[TaskSlots.ids[slot]]=command;maps[scope]=map;next.taskCommands=maps
        next.taskMappings?[scope]?[TaskSlots.ids[slot]]=nil
        setLayout(next)
    }

    func resetLayout() {
        // Reset the visible layout without changing the user's A/B models.
        setLayout(LayoutPreferences()); setScale(Self.defaultScale)
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
