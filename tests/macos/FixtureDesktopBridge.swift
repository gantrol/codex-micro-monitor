import AppKit

/// Test bundle only. Replaces the native boundary in a copied, separately
/// identified app; never links MicroCore or accesses the user's Codex.
@objc(MicroDesktopBridge) final class FixtureDesktopBridge: NSObject, DesktopServices {
    private var event:((String)->Void)?
    private var thread="01000000-0000-0000-0000-000000000001"
    private var draft=false
    private let nativeOnly=ProcessInfo.processInfo.environment["MICRO_E2E_NATIVE_ONLY"] == "1"
    private let workspaceActions=ProcessInfo.processInfo.environment["MICRO_E2E_WORKSPACE_ACTIONS"] == "1"
    private var state:[String:Any]=["model":"fixture-a","effort":"medium","serviceTier":NSNull(),"collaborationMode":["mode":"default"],"activeTurnId":"fixture-turn","approvals":[]]
    required override init() { super.init() }
    private var ui:[String:Any] {
        let native=nativeOnly && !draft
        return ["available":true,"routeAvailable":!native,"selectionKnown":!native,"threadId":draft || native ? NSNull() as Any : thread,
         "routeKey":native ? NSNull() as Any : draft ? "draft":"thread:"+thread,"draft":draft,"nativeComposer":native,"targetToken":"fixture-native",
         "canSubmit":true,"canDictate":true,"draftPlanAvailable":true,"draftFastAvailable":true,"draftReasoningAvailable":true,"settings":state]
    }
    func execute(_ id:String,operation:String,arguments:Data,reply:@escaping(Data?,NSError?)->Void) {
        DispatchQueue.main.async { [self] in
            let args=(try? JSONSerialization.jsonObject(with:arguments)) as? [String:Any] ?? [:]
            let result:[String:Any]
            switch operation {
            case "list_keypad_threads": result=["contextID":"fixture","threads":[["id":thread,"title":"Isolated fixture chat","status":["type":"idle"]]]]
            case "get_keypad_activity": result=["watching":true,"contextValid":true,"contextID":"fixture","revision":1,"streamConnected":true,"visibilityKnown":true,"visibleContexts":[thread],"settings":[:],"signals":[:]]
            case "get_keypad_layout": result=["slots":[:],"encoderMode":"reasoning","analogBindings":["up":["type":"command","commandId":"composer.togglePlanMode"]]]
            case "get_keypad_models": result=["data":[["model":"fixture-a","displayName":"Fixture A","defaultReasoningEffort":"medium","supportedReasoningEfforts":[["reasoningEffort":"low"],["reasoningEffort":"medium"],["reasoningEffort":"high"]],"serviceTiers":[["id":"fast"]]]]]
            case "get_keypad_usage": result=[:]
            case "get_keypad_capabilities": result=["forkAvailable":true]
            case "get_keypad_state": result=state.merging(["threadId":thread,"title":"Isolated fixture chat"]) { _,new in new }
            case "get_keypad_ui_state": result=ui
            case "open_keypad_developer_site", "open_keypad_folder":
                do {
                    if !workspaceActions { result=["launch_requested":true] }
                    else if operation == "open_keypad_developer_site" { result=try WorkspaceActions.developerSite { NSWorkspace.shared.open($0) } }
                    else {
                        guard args["thread_id"] as? String == thread, let folder=ProcessInfo.processInfo.environment["MICRO_E2E_FOLDER"] else {
                            throw NSError(domain:"Fixture",code:1)
                        }
                        result=try WorkspaceActions.folder(folder) { NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:$0.path) }
                    }
                } catch { reply(nil,error as NSError); return }
            default:
                if operation == "set_keypad_reasoning" || operation == "set_keypad_draft_reasoning" { state["effort"]=args["effort"] }
                if operation == "set_keypad_fast" || operation == "set_keypad_draft_fast" { state["serviceTier"]=(args["enabled"] as? Bool ?? !(state["serviceTier"] is String)) ? "fast" : NSNull() as Any }
                if operation == "new_keypad_thread" { draft=true }
                if operation == "open_keypad_thread", let id=args["thread_id"] as? String { thread=id; draft=false }
                if operation == "toggle_keypad_plan" || operation == "toggle_keypad_draft_plan" { state["collaborationMode"]=["mode":(state["collaborationMode"] as? [String:String])?["mode"] == "plan" ? "default":"plan"] }
                result=["applied":true,"verified":true,"navigation_verified":true,"state":operation.contains("draft") || operation.contains("composer") || operation.contains("sketch") || operation.contains("dictation") || operation.contains("ui") ? ui:state]
            }
            if !operation.hasPrefix("get_"), !operation.hasPrefix("list_"), let path=ProcessInfo.processInfo.environment["MICRO_E2E_LOG"], let line=try? JSONSerialization.data(withJSONObject:["operation":operation,"arguments":args],options:.sortedKeys) {
                if let file=FileHandle(forWritingAtPath:path) { file.seekToEndOfFile(); file.write(line+Data([10])); try? file.close() }
            }
            reply(try? JSONSerialization.data(withJSONObject:result),nil)
        }
    }
    func cancel(_ id:String) {}
    func close(_ reply:@escaping()->Void) { reply() }
    func runMCP() {}
    func install(_ event:@escaping(String)->Void) { self.event=event }
    func configureWindow(_ title:String,scale:Double,floating:Bool)->Bool {
        guard let window=NSApp.windows.first(where: { $0.isVisible }) else { return false }
        window.title="Micro Isolated E2E"; window.setContentSize(NSSize(width:590*scale,height:610*scale)); return true
    }
    func setSettingsVisible(_ visible:Bool) { NSApp.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width:visible ? 720:442.5,height:visible ? 760:457.5)) }
    func showWindow() { NSApp.activate(ignoringOtherApps:true) }
    func hideWindow() { NSApp.hide(nil) }
    func centerWindow() { NSApp.windows.first?.center() }
    func dragWindow() {}
    func showMenu() { event?("settings") }
}
