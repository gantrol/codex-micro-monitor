import AppKit
import MicroCore

enum NativeFilePicker {
    enum Kind:String {
        case files,photos
        var items:[String] {self == .files ? ["Files and folders","文件和文件夹","檔案及資料夾","檔案和資料夾"]:["Add photos","添加照片","加入相片","新增相片"]}
        var titles:[String] {self == .files ? ["Select files","选择文件","選取檔案"]:["Select photos","选择照片","選取相片"]}
    }
    static func dialog(_ node:AXNode) -> Bool {
        (["AXDialog","AXSheet"].contains(node.role) || node.subrole == "AXDialog") &&
            node.rect.width > 0 && node.rect.height > 0
    }
    static func photosShortcut(_ io:NativeUIAccess) -> MacShortcut? {
        guard let shortcut=try? io.shortcut("composer.addPhotos") else {return nil}
        let functionKeys:[CGKeyCode]=[122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        // A content key such as bare Return must never become a speculative
        // attachment shortcut. Only explicit command chords or function keys.
        guard !shortcut.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty || functionKeys.contains(shortcut.key) else {return nil}
        return shortcut
    }
    static func open(_ kind:Kind = .files,before:MacUISnapshot,io:NativeUIAccess,context:UIRequestContext,
                     capture:() throws -> MacUISnapshot,mutation:() -> Void) throws -> String {
        let windows=try io.windows(before.app.processIdentifier,context)
        guard !windows.contains(where:{dialog($0) && $0.named(Kind.files.titles+Kind.photos.titles)}) else {throw CodexClientError.unavailable("An attachment picker is already open.")}
        func waitPicker() throws {
            let end=ProcessInfo.processInfo.systemUptime+2.5
            repeat {
                try context.check()
                let current=try io.windows(before.app.processIdentifier,context)
                let created=current.filter {candidate in dialog(candidate) && !windows.contains(where:{MacAX.same($0.element,candidate.element)})}
                if created.count == 1,created[0].named(kind.titles) {return}
                Thread.sleep(forTimeInterval:0.04)
            } while ProcessInfo.processInfo.systemUptime < end
            throw CodexClientError.outcomeUnknown
        }
        let initial=try capture()
        guard initial.menuItems.isEmpty,initial.composerMenuItems.isEmpty,initial.topLevelMenus.isEmpty else {throw CodexClientError.unavailable("The composer menu is already open.")}
        if kind == .photos,let shortcut=photosShortcut(io) {
            mutation();try io.send(shortcut,before.app.processIdentifier) {
                let ready=try capture()
                guard ready.menuItems.isEmpty,ready.composerMenuItems.isEmpty,ready.topLevelMenus.isEmpty,
                      io.foreground() == before.app.processIdentifier,photosShortcut(io) == shortcut else {throw CodexClientError.staleTarget}
            }
            try waitPicker()
            return "configuredShortcut"
        }
        guard let add=initial.unique(initial.controls,matching:{$0.enabled && $0.named(MacUISnapshot.addNames)}) else {throw CodexClientError.unavailable("The composer add menu is unavailable.")}
        var popup:AXUIElement?
        defer {
            // The picker is a separate native modal window. Never send Escape
            // to it, a permission dialog, or another chat's popup.
            if let popup,let state=try? capture(),!state.blocked,
               state.nodes.contains(where:{MacAX.same($0.element,popup)}),
               state.controls.contains(where:{MacAX.same(state.nodes[$0].element,add.element) && state.nodes[$0].expanded == true}) {
                try? io.send(.init(key:53,flags:[]),before.app.processIdentifier) {
                    let current=try capture()
                    guard io.foreground() == before.app.processIdentifier,
                          current.nodes.contains(where:{MacAX.same($0.element,popup)}) else {throw CodexClientError.staleTarget}
                }
            }
        }
        mutation();try io.press(add.element)
        let end=ProcessInfo.processInfo.systemUptime+2.5
        var opened:MacUISnapshot?
        repeat {
            try context.check()
            let state=try capture()
            if !state.composerMenuItems.isEmpty {opened=state;break}
            Thread.sleep(forTimeInterval:0.04)
        } while ProcessInfo.processInfo.systemUptime < end
        guard let opened else {throw CodexClientError.outcomeUnknown}
        // Retain the unique owned popup even if the requested item is absent.
        let roots=Set(opened.composerMenuItems.compactMap { index -> Int? in
            var parent=opened.nodes[index].parent
            while let at=parent {
                if ["AXMenu","AXList","AXListBox"].contains(opened.nodes[at].role) {return at}
                parent=opened.nodes[at].parent
            }
            return nil
        })
        guard roots.count == 1,let root=roots.first else {throw CodexClientError.unavailable("The composer menu is ambiguous.")}
        popup=opened.nodes[root].element
        guard let item=opened.unique(opened.composerMenuItems,matching:{$0.enabled && $0.named(kind.items)}) else {throw CodexClientError.unavailable("The requested attachment command is unavailable in this composer.")}
        let ready=try capture()
        guard ready.composerMenuItems.contains(where:{MacAX.same(ready.nodes[$0].element,item.element) && ready.nodes[$0].enabled && ready.nodes[$0].name == item.name}) else {throw CodexClientError.staleTarget}
        mutation();try io.press(item.element)
        try waitPicker()
        popup=nil
        return "menu"
    }
}
