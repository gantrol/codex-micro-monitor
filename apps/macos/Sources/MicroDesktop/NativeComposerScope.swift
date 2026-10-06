import Foundation

/// The complete-tree observer and the focused-element fallback use the same
/// ancestry rule. Window geometry and labels outside this scope confer no authority.
struct NativeComposerScope {
    struct Ancestor {
        let role: String
        let identifier: String
    }
    static func allows(_ ancestors: [Ancestor]) -> Bool {
        !ancestors.contains { $0.identifier.hasPrefix("app-shell-tab-panel-") } &&
            ancestors.filter { $0.role == "AXWebArea" }.count <= 1
    }

    let composer: Int?
    let container: Int?
    let controls: [Int]
    let candidateCount: Int

    init(nodes: [AXNode], tree: AXTreeIndex, modelLabels: [String]) {
        func belongsToMainComposer(_ index: Int) -> Bool {
            var ancestors: [Ancestor] = [], parent = nodes[index].parent
            for _ in 0..<80 {
                guard let at = parent else { return Self.allows(ancestors) }
                guard nodes.indices.contains(at) else { return false }
                ancestors.append(.init(role: nodes[at].role, identifier: nodes[at].identifier))
                parent = nodes[at].parent
            }
            return false
        }
        let candidates = nodes.indices.filter {
            nodes[$0].enabled && nodes[$0].rect.width > 0 && nodes[$0].rect.height > 0 &&
                ["AXTextArea", "AXTextField"].contains(nodes[$0].role) &&
                nodes[$0].classes.contains("ProseMirror") && belongsToMainComposer($0)
        }
        candidateCount = candidates.count
        composer = candidates.count == 1 ? candidates[0] : nil
        var foundContainer: Int?, foundControls: [Int] = []
        if let composer {
            var parent = nodes[composer].parent
            for _ in 0..<80 {
                guard let at = parent, nodes.indices.contains(at),
                      !["AXWindow", "AXWebArea"].contains(nodes[at].role) else { break }
                let buttons = (tree.buttonsByAncestor[at] ?? []).filter(belongsToMainComposer)
                if buttons.contains(where: { nodes[$0].named(MacUISnapshot.sendNames + MacUISnapshot.stopNames + MacUISnapshot.addNames) }) {
                    let hasPicker = buttons.contains { MacUISnapshot.matchesPicker(tree.strings(under: $0, nodes: nodes), modelLabels: modelLabels) }
                    // Preserve the nearest action row when the picker is absent.
                    // Do not absorb all transcript/header buttons on the way up.
                    if foundContainer == nil || hasPicker { foundContainer = at; foundControls = buttons }
                    if hasPicker { break }
                }
                parent = nodes[at].parent
            }
        }
        container = foundContainer
        controls = foundControls
    }
}
