import Foundation
import CoreFoundation

public enum ClientThreadIdentity {
    public static func canonical(_ value:String)->String? {
        let prefix="client-new-thread:"
        guard value.hasPrefix(prefix) else {return nil}
        let suffix=String(value.dropFirst(prefix.count))
        guard suffix.count == 36,let id=UUID(uuidString:suffix) else {return nil}
        return prefix+id.uuidString.lowercased()
    }
    public static func fromRoute(_ key:String?)->String? {
        guard let key,key.hasPrefix("client:") else {return nil}
        return canonical(String(key.dropFirst(7)))
    }
}

// A route/selection pair is a candidate, not proof that the identities agree.
public struct ClientRoutePair:Equatable,Sendable {
    public let clientThreadID:String
    public let threadID:String
    public let documentIsClient:Bool
    public init?(clientThreadID:String,threadID:String,documentIsClient:Bool) {
        guard ClientThreadIdentity.canonical(clientThreadID) == clientThreadID,
              threadID.count == 36,UUID(uuidString:threadID)?.uuidString.lowercased() == threadID else {return nil}
        self.clientThreadID=clientThreadID;self.threadID=threadID;self.documentIsClient=documentIsClient
    }
    public var routeKey:String {"binding:"+(documentIsClient ? "client:":"thread:")+clientThreadID+":"+threadID}
    public var dictionary:[String:Any] {["clientThreadId":clientThreadID,"threadId":threadID,"documentIsClient":documentIsClient]}
    public init?(_ raw:[String:Any]) {
        guard let client=raw["clientThreadId"] as? String,let thread=raw["threadId"] as? String,let direction=raw["documentIsClient"] as? Bool else {return nil}
        self.init(clientThreadID:client,threadID:thread,documentIsClient:direction)
    }
}

// Used by the panel and the dispatch boundary. A known client route is a
// settings-only identity; an unknown route still needs the native fallback.
public enum NativeComposerIdentity {
    public static func settingsOnly(_ state:[String:Any])->Bool {
        guard state["available"] as? Bool == true,state["nativeComposer"] as? Bool == true,
              state["draft"] as? Bool != true,state["threadId"] as? String == nil else {return false}
        if let route=state["routeKey"] as? String {
            guard state["selectionKnown"] as? Bool == true,let client=ClientThreadIdentity.fromRoute(route) else {return false}
            return state["clientThreadId"] as? String == client
        }
        return state["selectionKnown"] as? Bool != true && state["clientThreadId"] as? String == nil
    }
}

public enum TaskLampSignal:String,CaseIterable {
    case unknown,idle,running,waiting,question,unread,error
    public init(status:[String:Any]) {self=Self.classify(status:status)}
    public static func classify(status:[String:Any],question:Bool=false,approval:Bool=false,unread:Bool=false)->Self {
        let type=status["type"] as? String,flags=status["activeFlags"] as? [String] ?? []
        if type == "systemError" {return .error}
        if approval || flags.contains("waitingOnApproval") {return .waiting}
        if question || flags.contains("waitingOnUserInput") {return .question}
        if type == "active" {return .running}
        if unread {return .unread}
        return type == "idle" ? .idle:.unknown
    }
}

// Renderer priority is attention, not the lamp's visual status. A running
// unread chat ranks as unread; an error alone is not a pending user request.
public enum TaskAttention:String,CaseIterable {
    case waiting,unread,active,idle
    public var rank:Int {Self.allCases.firstIndex(of:self)!}
    public static func classify(status:[String:Any],question:Bool=false,approval:Bool=false,unread:Bool=false)->Self {
        let flags=status["activeFlags"] as? [String] ?? []
        if question || approval || flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") {return .waiting}
        if unread {return .unread}
        return status["type"] as? String == "active" ? .active:.idle
    }
    public static func recency(_ row:[String:Any])->Double {
        for key in ["recencyAt","updatedAt","createdAt"] {
            if let number=row[key] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite {
                return number.doubleValue
            }
        }
        return 0
    }
}

public enum ComposerTextPreset:String,CaseIterable {
    case yolo="YOLO",yeet="YEET"
    public var text:String {":"+rawValue.lowercased()+":"}
    public static func matching(_ text:String?) -> Self? {allCases.first {$0.text == text}}
}

// Only Objective-C/Foundation values cross the macOS / Mac Catalyst boundary.
@MainActor @objc(MicroDesktopServices) public protocol DesktopServices: NSObjectProtocol {
    init()
    func execute(_ id: String, operation: String, arguments: Data, reply: @escaping (Data?, NSError?) -> Void)
    func cancel(_ id: String)
    func close(_ reply: @escaping () -> Void)
    func runMCP()
    func install(_ event: @escaping (String) -> Void)
    func installScrollInput(_ input: @escaping (Double, Double, Double, Double, Bool, String) -> Bool)
    func configureWindow(_ title: String, scale: Double, floating: Bool) -> Bool
    func setSettingsVisible(_ visible: Bool)
    func showWindow()
    func hideWindow()
    func centerWindow()
    func dragWindow()
    func showMenu()
}
