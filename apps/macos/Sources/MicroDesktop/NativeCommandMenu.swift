import AppKit
import ApplicationServices
import MicroCore

/// Selects one observed command without changing search or typing into forms.
/// Callers define their exact selection and readback; unknown outcomes stay so.
enum NativeCommandMenu {
    static let openMenu=["Open command menu","打开命令菜单","開啟指令選單"]
    static let menuTitles=["Command menu","命令菜单","指令選單","指令功能表"]
    static let projectNames=["Project","项目","項目","專案"]
    static func projectGroup(_ state:MacUISnapshot,in palette:Int) -> Int? {
        let groups=state.nodes.indices.filter {
            state.nodes[$0].role == "AXGroup" && state.nodes[$0].named(projectNames) &&
                state.nodes[$0].rect.width > 0 && state.nodes[$0].rect.height > 0 &&
                MacUISnapshot.within($0,ancestor:palette,nodes:state.nodes)
        }
        return groups.count == 1 ? groups[0]:nil
    }
    static func dialog(_ state:MacUISnapshot,named titles:[String],requiring:(Int)->Bool) -> Int? {
        let dialogs=state.nodes.indices.filter { index in
            let node=state.nodes[index]
            return (["AXDialog","AXSheet"].contains(node.role) || node.subrole == "AXDialog") &&
                node.rect.width > 0 && node.rect.height > 0
        }
        let matches=dialogs.filter { index in
            let node=state.nodes[index]
            return dialogs.allSatisfy { $0 == index || MacUISnapshot.within($0,ancestor:index,nodes:state.nodes) } &&
                (node.named(titles) || state.nodes.indices.contains { MacUISnapshot.within($0,ancestor:index,nodes:state.nodes) && state.nodes[$0].named(titles) }) && requiring(index)
        }
        return matches.count == 1 ? matches[0]:nil
    }
    static func palette(_ state:MacUISnapshot) -> Int? {
        dialog(state,named:menuTitles) { parent in
            state.nodes.indices.contains { ($0 == parent || MacUISnapshot.within($0,ancestor:parent,nodes:state.nodes)) && state.nodes[$0].classes.contains("global-command-menu-dialog") }
        }
    }
    static func item(_ state:MacUISnapshot,in parent:Int,names:[String],selected:Bool=false) -> AXNode? {
        state.unique(state.nodes.indices.filter { index in
            let node=state.nodes[index]
            guard ["AXRow","AXMenuItem"].contains(node.role),node.rect.width > 0,node.rect.height > 0,
                  MacUISnapshot.within(index,ancestor:parent,nodes:state.nodes),!selected || node.selected else { return false }
            return node.named(names) || state.nodes.indices.contains {
                state.nodes[$0].role == "AXStaticText" && state.nodes[$0].named(names) && MacUISnapshot.within($0,ancestor:index,nodes:state.nodes)
            }
        }) { _ in true }
    }
    static func perform(before:MacUISnapshot,io:NativeUIAccess,context:UIRequestContext,
                     capture:() throws -> MacUISnapshot,mutation:() -> Void,
                     select:(MacUISnapshot,Int)->AXNode?,completed:(MacUISnapshot)->Bool) throws -> MacUISnapshot {
        guard let thread=before.thread,!before.blocked,before.topLevelMenus.isEmpty,before.composerMenuItems.isEmpty else {throw CodexClientError.staleTarget}
        func current() throws -> MacUISnapshot {
            try context.check()
            let state=try capture()
            guard state.thread == thread,state.route == before.route else {throw CodexClientError.staleTarget}
            return state
        }
        func wait(_ condition:(MacUISnapshot)->Bool) throws -> MacUISnapshot {
            let end=ProcessInfo.processInfo.systemUptime+2.5
            repeat {
                let state=try current()
                if condition(state) {return state}
                Thread.sleep(forTimeInterval:0.04)
            } while ProcessInfo.processInfo.systemUptime < end
            throw CodexClientError.outcomeUnknown
        }
        guard let command=try io.applicationCommand(before.app.processIdentifier,openMenu,context) else {throw CodexClientError.unavailable("The native command menu is unavailable.")}
        let state=try current()
        guard !state.blocked,state.topLevelMenus.isEmpty,
              let checked=try io.applicationCommand(before.app.processIdentifier,openMenu,context),MacAX.same(command.element,checked.element) else {throw CodexClientError.staleTarget}
        var owned:AXUIElement?
        defer {
            // Only dismiss the exact palette opened here. Another form, system
            // permission prompt, or another chat's menu must stay untouched.
            if let owned,let state=try? current(),let index=palette(state),MacAX.same(state.nodes[index].element,owned) {
                try? io.send(.init(key:53,flags:[]),before.app.processIdentifier) {
                    let latest=try current()
                    guard io.foreground() == before.app.processIdentifier,let at=palette(latest),MacAX.same(latest.nodes[at].element,owned) else {throw CodexClientError.staleTarget}
                }
            }
        }
        mutation();try io.press(checked.element)
        let opened=try wait {palette($0) != nil}
        guard let parent=palette(opened) else {throw CodexClientError.outcomeUnknown}
        owned=opened.nodes[parent].element
        guard let selected=select(opened,parent),selected.enabled else {throw CodexClientError.unavailable("The requested native command is unavailable for this chat.")}
        let fresh=try current()
        guard let scope=palette(fresh),MacAX.same(fresh.nodes[scope].element,owned),
              let checkedItem=select(fresh,scope),checkedItem.enabled,MacAX.same(checkedItem.element,selected.element),
              opened.strings(under:selected.element) == fresh.strings(under:checkedItem.element) else {throw CodexClientError.staleTarget}
        mutation();try io.press(checkedItem.element)
        let after=try wait {palette($0) == nil && completed($0)}
        owned=nil
        return after
    }
}
