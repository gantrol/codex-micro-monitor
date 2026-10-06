import AppKit
import MicroCore

enum NativeEnvironmentAction {
    static let runPrefixes=["Run: ","运行：","執行："]

    static func firstAction(_ state:MacUISnapshot,in palette:Int) -> AXNode? {
        let children=state.nodes.indices.filter {MacUISnapshot.within($0,ancestor:palette,nodes:state.nodes)}
        // Filtering changes command order. Never clear a user's search or infer
        // slot 1 from a filtered list, the MRU Run button, or a chat result.
        guard let search=state.unique(children,matching:{["AXTextField","AXComboBox"].contains($0.role)}),search.text == "" else {return nil}
        guard let group=NativeCommandMenu.projectGroup(state,in:palette) else {return nil}
        let rows=children.filter { index in
            ["AXRow","AXMenuItem"].contains(state.nodes[index].role) && MacUISnapshot.within(index,ancestor:group,nodes:state.nodes)
        }
        func titles(_ index:Int) -> [String] {
            state.nodes.indices.filter {state.nodes[$0].role == "AXStaticText" && MacUISnapshot.within($0,ancestor:index,nodes:state.nodes)}.map {state.nodes[$0].name}.filter {text in runPrefixes.contains {text.hasPrefix($0) && text.count > $0.count}}
        }
        guard let first=rows.first(where:{index in !titles(index).isEmpty || runPrefixes.contains {state.nodes[index].name.hasPrefix($0)}}),
              Set(titles(first)).count <= 1 else {return nil}
        let node=state.nodes[first]
        // Keep disabled slot 1 as unavailable instead of silently running slot 2.
        guard node.enabled,node.rect.width > 0,node.rect.height > 0,
              !titles(first).isEmpty || runPrefixes.contains(where:{node.name.hasPrefix($0) && node.name.count > $0.count}) else {return nil}
        return node
    }

    static func terminals(_ state:MacUISnapshot) -> [AXNode] {
        guard let thread=state.thread else {return []}
        let prefix="terminal-panel-environment-action:"+thread+":"
        let suffix=":environmentAction1"
        return state.nodes.indices.filter { index in
            let node=state.nodes[index]
            guard node.identifier.hasPrefix(prefix),node.identifier.hasSuffix(suffix),
                  node.identifier.count > prefix.count+suffix.count,node.rect.width > 0,node.rect.height > 0,
                  !MacUISnapshot.hasAncestor(index,nodes:state.nodes,matching:{$0.role == "AXWebArea" && !$0.documentURLs.contains(where:{CurrentRoute.documentPath($0) != nil})}) else {return false}
            return state.nodes.indices.contains { parent in
                state.nodes[parent].identifier.hasPrefix("app-shell-tab-panel-") && state.nodes[parent].rect.width > 0 && state.nodes[parent].rect.height > 0 &&
                    MacUISnapshot.within(index,ancestor:parent,nodes:state.nodes)
            } && state.nodes.indices.contains {
                state.nodes[$0].classes.contains("xterm-helper-textarea") && MacUISnapshot.within($0,ancestor:index,nodes:state.nodes)
            }
        }.map {state.nodes[$0]}
    }

    static func run(before:MacUISnapshot,io:NativeUIAccess,context:UIRequestContext,
                    capture:() throws -> MacUISnapshot,mutation:() -> Void) throws -> MacUISnapshot {
        try NativeCommandMenu.perform(before:before,io:io,context:context,capture:capture,mutation:mutation,
            select:{firstAction($0,in:$1)},completed:{!$0.blocked && terminals($0).count == 1})
    }
}
