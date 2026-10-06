import AppKit
import ApplicationServices
import MicroCore

struct NativeClipboardState: Equatable {
    let changeCount:Int
    let text:String?
}

enum NativeThreadMenu {
    enum Action { case pin, copyMarkdown, archive, sideChat }
    static let triggers=["Chat actions","聊天操作","對話操作","對話動作"]
    static let pin=["Pin","Pin chat","置顶","固定","釘選"]
    static let unpin=["Unpin","Unpin chat","取消置顶","取消固定","取消釘選"]
    static let archive=["Archive","Archive chat","归档","归档聊天","封存","封存對話"]
    static let copy=["Copy as Markdown","复制为 Markdown","複製為 Markdown","複製為 Markdown 格式"]
    static let copyGroup=["Copy","复制","複製"]
    static let copied=["Copied conversation as Markdown","已将对话复制为 Markdown","已將對話複製為 Markdown","已將對話複製為 Markdown 格式"]
    static let sideChat=["New side chat","新建侧边聊天","新增側邊對話"]

    struct Result { let state:MacUISnapshot;let fields:[String:Any] }
    static func perform(_ action:Action, before:MacUISnapshot, io:NativeUIAccess, context:UIRequestContext,
                        capture:() throws -> MacUISnapshot, captureAfterNavigation:() throws -> MacUISnapshot,
                        mutation:() -> Void) throws -> Result {
        guard let thread=before.thread,before.menuItems.isEmpty,before.topLevelMenus.isEmpty,
              before.threadMenuTrigger != nil else { throw CodexClientError.unavailable("The exact chat's actions menu is unavailable.") }
        var ownedMenu:AXUIElement?
        func wait(_ check:(MacUISnapshot)->Bool, archive:Bool=false) throws -> MacUISnapshot {
            let end=ProcessInfo.processInfo.systemUptime+2.5
            repeat {
                try context.check()
                let state=try archive ? captureAfterNavigation():capture()
                if check(state) { return state }
                Thread.sleep(forTimeInterval:0.04)
            } while ProcessInfo.processInfo.systemUptime < end
            throw CodexClientError.outcomeUnknown
        }
        func press(_ node:AXNode, submenu:Bool=false) throws {
            let state=try capture()
            guard node.enabled,state.nodes.contains(where:{MacAX.same($0.element,node.element) && $0.enabled && $0.name == node.name && $0.role == node.role}) else { throw CodexClientError.staleTarget }
            mutation()
            if submenu { try io.expand(node.element) } else { try io.press(node.element) }
        }
        func open() throws -> MacUISnapshot {
            let state=try capture()
            guard state.topLevelMenus.isEmpty,let trigger=state.threadMenuTrigger else { throw CodexClientError.staleTarget }
            try press(trigger)
            let opened=try wait { $0.topLevelMenus.count == 1 && !$0.menuItems.isEmpty }
            ownedMenu=opened.nodes[opened.topLevelMenus[0]].element
            return opened
        }
        func item(_ state:MacUISnapshot,_ names:[String]) -> AXNode? {
            guard let ownedMenu,let menu=state.nodes.firstIndex(where:{MacAX.same($0.element,ownedMenu)}) else { return nil }
            return state.unique(state.menuItems.filter { MacUISnapshot.within($0,ancestor:menu,nodes:state.nodes) }) { $0.named(names) }
        }
        func close() throws -> MacUISnapshot {
            let state=try capture()
            if let ownedMenu,state.topLevelMenus.contains(where:{MacAX.same(state.nodes[$0].element,ownedMenu)}) {
                try io.send(.init(key:53,flags:[]),before.app.processIdentifier) {
                    let current=try capture()
                    guard io.foreground() == before.app.processIdentifier,
                          current.topLevelMenus.contains(where:{MacAX.same(current.nodes[$0].element,ownedMenu)}) else { throw CodexClientError.staleTarget }
                }
            }
            ownedMenu=nil
            return try wait { $0.topLevelMenus.isEmpty }
        }
        defer {
            // Never dismiss a confirmation or a different chat's popup.
            if ownedMenu != nil,let current=try? capture(),!current.blocked { _ = try? close() }
        }
        if action == .copyMarkdown,before.nodes.contains(where:{$0.named(copied)}) {
            throw CodexClientError.unavailable("Wait for the previous copy notification to finish before copying again.")
        }
        var current=try open()
        switch action {
        case .sideChat:
            guard let selected=item(current,sideChat) else { throw CodexClientError.unavailable("New side chat is unavailable for this chat.") }
            let existing=Set(current.sideChatPanels.map(\.identifier))
            try press(selected)
            func created(_ state:MacUISnapshot) -> [AXNode] {
                state.sideChatPanels.filter { $0.rect.width > 0 && $0.rect.height > 0 && !existing.contains($0.identifier) }
            }
            current=try wait({ state in
                state.thread == thread && !state.blocked && state.topLevelMenus.isEmpty && created(state).count == 1
            },archive:true)
            ownedMenu=nil
            return .init(state:current,fields:["verified":true,"parentThreadId":thread,"sideChatOpened":true,"sideChatPanel":created(current)[0].identifier])
        case .pin:
            let add=item(current,pin),remove=item(current,unpin)
            guard (add == nil) != (remove == nil),let selected=add ?? remove else { throw CodexClientError.unavailable("Pin state is ambiguous or unavailable.") }
            let desired=add != nil
            try press(selected)
            _ = try wait { $0.topLevelMenus.isEmpty }
            ownedMenu=nil;current=try open()
            guard item(current,desired ? unpin:pin) != nil,item(current,desired ? pin:unpin) == nil else { throw CodexClientError.outcomeUnknown }
            return .init(state:try close(),fields:["verified":true,"threadId":thread,"pinned":desired])
        case .copyMarkdown:
            if item(current,copy) == nil {
                guard let group=item(current,copyGroup) else { throw CodexClientError.unavailable("Copy as Markdown is unavailable for this chat.") }
                try press(group,submenu:true)
                current=try wait { item($0,copy) != nil }
            }
            guard let selected=item(current,copy) else { throw CodexClientError.unavailable("Copy as Markdown is unavailable for this chat.") }
            guard !current.nodes.contains(where:{$0.named(copied)}) else { throw CodexClientError.staleTarget }
            let baseline=io.clipboardCount()
            try press(selected)
            current=try wait { state in
                guard state.topLevelMenus.isEmpty,state.nodes.contains(where:{$0.named(copied)}),io.clipboardCount() == baseline+1 else { return false }
                let clipboard=io.clipboard()
                return clipboard.changeCount == baseline+1 && !(clipboard.text?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true)
            }
            let clipboard=io.clipboard()
            guard clipboard.changeCount == baseline+1,let text=clipboard.text,!text.isEmpty else { throw CodexClientError.outcomeUnknown }
            ownedMenu=nil
            // Do not return or log conversation contents from the pasteboard.
            return .init(state:current,fields:["verified":true,"threadId":thread,"clipboard_updated":true,"characters":text.count])
        case .archive:
            guard let selected=item(current,archive) else { throw CodexClientError.unavailable("Archive is unavailable for this chat.") }
            try press(selected)
            current=try wait({ $0.blocked || $0.topLevelMenus.isEmpty },archive:true)
            ownedMenu=nil
            // Codex owns confirmations and worktree cleanup. A disappeared
            // menu/chat is not proof that archive persisted; the backend checks.
            return .init(state:current,fields:["verified":false,"archive_requested":true,"threadId":thread,"pending_confirmation":current.blocked])
        }
    }

    static func confirmArchive(_ requested:[String:Any],observe:(String) async throws -> [String:Any],
                               pause:() async throws -> Void = { try await Task.sleep(for:.milliseconds(150)) }) async throws -> [String:Any] {
        guard requested["archive_requested"] as? Bool == true,let id=requested["threadId"] as? String,UUID(uuidString:id) != nil else { throw CodexClientError.staleTarget }
        var result=requested
        guard result["pending_confirmation"] as? Bool != true else { return result }
        do {
            for attempt in 0..<6 {
                try Task.checkCancellation()
                let state=try await observe(id)
                guard state["threadId"] as? String == id else { throw CodexClientError.staleTarget }
                if state["archived"] as? Bool == true { result["verified"]=true;result["archived"]=true;return result }
                if attempt < 5 { try await pause() }
            }
        } catch { result["followupError"]=error.localizedDescription }
        result["verified"]=false
        return result
    }
}

extension MacUISnapshot {
    var topLevelMenus:[Int] {
        nodes.indices.filter { nodes[$0].role == "AXMenu" && nodes[$0].rect.width > 0 && nodes[$0].rect.height > 0 && !Self.hasAncestor($0,nodes:nodes,matching:{$0.role == "AXMenu"}) }
    }
    var threadMenuTrigger:AXNode? {
        guard thread != nil else { return nil }
        return unique(nodes.indices.filter { index in
            !nodes[index].classes.contains("sidebar-item") && !Self.hasAncestor(index,nodes:nodes,matching:{$0.classes.contains("sidebar-item")})
        }) { $0.enabled && $0.button && $0.named(NativeThreadMenu.triggers) }
    }
}
