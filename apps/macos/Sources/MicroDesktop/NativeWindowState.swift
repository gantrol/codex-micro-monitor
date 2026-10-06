import AppKit
import MicroCore

enum NativeWindowNavigation {
    static let actions=["sidebar","back","forward"]

    static func button(_ action:String,in state:MacUISnapshot) -> AXNode? {
        guard actions.contains(action),!state.blocked,state.route != "conflict",
              state.route != nil || state.nativeComposer,
              state.topLevelMenus.isEmpty,state.composerMenuItems.isEmpty else {return nil}
        let labels = action == "sidebar" ? MacUISnapshot.sidebarNames : action == "back" ?
            ["Back","后退","返回","上一页","上一頁"] : ["Forward","前进","下一页","下一頁"]
        return state.unique(Array(state.nodes.indices)) {
            $0.enabled && $0.button && $0.named(labels) && $0.rect.width > 0 && $0.rect.height > 0 &&
                (action == "sidebar" || $0.rect.minY < (state.nodes.first?.rect.minY ?? 0)+100)
        }
    }

    static func perform(_ action:String,before:MacUISnapshot,io:NativeUIAccess,models:[[String:Any]],context:UIRequestContext) throws -> MacUISnapshot {
        guard button(action,in:before) != nil else {throw CodexClientError.unavailable("Window navigation control is unavailable.")}
        func capture(preserveTarget:Bool) throws -> MacUISnapshot {
            try context.check()
            let state=try io.capture(context,models.flatMap(MacUIController.modelLabels))
            guard before.app.processIdentifier == state.app.processIdentifier,MacAX.same(before.window,state.window),!state.blocked else {throw CodexClientError.staleTarget}
            if preserveTarget {
                guard before.sameTarget(state,text:true),before.clientBinding == state.clientBinding,
                      before.settings as NSDictionary == state.settings as NSDictionary else {throw CodexClientError.staleTarget}
            }
            return state
        }
        _ = try capture(preserveTarget:true)
        if io.foreground() != before.app.processIdentifier {
            guard io.activate(before.app) else {throw CodexClientError.unavailable("Codex could not become the active application.")}
            let end=ProcessInfo.processInfo.systemUptime+1
            while io.foreground() != before.app.processIdentifier && ProcessInfo.processInfo.systemUptime < end {
                try context.check();Thread.sleep(forTimeInterval:0.02)
            }
        }
        guard io.foreground() == before.app.processIdentifier,
              let control=button(action,in:try capture(preserveTarget:true)) else {throw CodexClientError.staleTarget}
        do {
            try io.press(control.element)
            let end=ProcessInfo.processInfo.systemUptime+2.5
            repeat {
                // Hiding the sidebar can remove its selected-chat identity;
                // history deliberately changes it. Read back the same window.
                let state=try capture(preserveTarget:false)
                if action == "sidebar" {
                    if let next=button(action,in:state),next.name != control.name {return state}
                } else if let route=state.route,route != "conflict",route != before.route {return state}
                Thread.sleep(forTimeInterval:0.04)
            } while ProcessInfo.processInfo.systemUptime < end
        } catch {throw CodexClientError.outcomeUnknown}
        throw CodexClientError.outcomeUnknown
    }
}

extension MacUISnapshot {
    static let feedbackCommands=["Send Feedback","反馈","意見","回饋意見"]
    static let feedbackTitles=["Share feedback","提交反馈","提交意見","提供意見回饋"]
    static let feedbackDetails=["Share details (required)","填写详情（必填）","提供詳情（必填）","分享詳細資訊（必填）"]
    static let feedbackOptions=["Feedback options","反馈选项","意見選項","意見回饋選項"]

    var feedbackDialog:AXNode? {
        unique(nodes.indices.filter { index in
            let node=nodes[index]
            guard ["AXDialog","AXSheet"].contains(node.role) || node.subrole == "AXDialog",
                  node.rect.width > 0,node.rect.height > 0 else { return false }
            let children=nodes.indices.filter { Self.within($0,ancestor:index,nodes:nodes) }
            return (node.named(Self.feedbackTitles) || children.contains { nodes[$0].named(Self.feedbackTitles) }) &&
                children.contains { nodes[$0].role == "AXTextArea" && nodes[$0].named(Self.feedbackDetails) } &&
                children.contains { ["AXGroup","AXRadioGroup"].contains(nodes[$0].role) && nodes[$0].named(Self.feedbackOptions) }
        }) { _ in true }
    }

    var sideChatPanels:[AXNode] {
        let titles=["Side chat","侧边聊天","側邊對話","側邊聊天室"]
        return nodes.indices.filter { panel in
            let node=nodes[panel]
            guard node.identifier.hasPrefix("app-shell-tab-panel-") else { return false }
            let title=node.name.trimmingCharacters(in:.whitespacesAndNewlines)
            let named=titles.contains { base in
                if title == base {return true}
                guard title.hasPrefix(base+" ") else {return false}
                let suffix=title.dropFirst(base.count+1)
                return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
            }
            return named && nodes.indices.contains { index in
                ["AXTextArea","AXTextField"].contains(nodes[index].role) && nodes[index].classes.contains("ProseMirror") &&
                    nodes[index].rect.width > 0 && nodes[index].rect.height > 0 &&
                    Self.within(index,ancestor:panel,nodes:nodes)
            }
        }.map {nodes[$0]}
    }
}
