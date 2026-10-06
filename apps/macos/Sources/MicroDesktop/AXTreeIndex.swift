import ApplicationServices

/// Built once per complete capture. Queries walk only the relevant subtree,
/// rather than rescanning the entire chat transcript for every composer button.
struct AXTreeIndex {
    private let children: [Int: [Int]]
    private let elements: [CFHashCode: [Int]]
    let buttonsByAncestor: [Int: [Int]]

    init(_ nodes: [AXNode]) {
        var children: [Int: [Int]] = [:], elements: [CFHashCode: [Int]] = [:], buttons: [Int: [Int]] = [:]
        for index in nodes.indices {
            if let parent = nodes[index].parent { children[parent, default: []].append(index) }
            elements[CFHash(nodes[index].element), default: []].append(index)
            guard nodes[index].button, nodes[index].rect.width > 0, nodes[index].rect.height > 0 else { continue }
            var parent = nodes[index].parent
            for _ in 0..<80 {
                guard let ancestor = parent, nodes.indices.contains(ancestor) else { break }
                buttons[ancestor, default: []].append(index)
                parent = nodes[ancestor].parent
            }
        }
        self.children = children; self.elements = elements; buttonsByAncestor = buttons
    }

    func index(of element: AXUIElement, nodes: [AXNode]) -> Int? {
        elements[CFHash(element)]?.first { MacAX.same(nodes[$0].element, element) }
    }

    enum MenuRelationship {
        case noMenu
        case menu(Int)
        case unavailable
    }

    func linkedMenu(for node: AXNode, nodes: [AXNode]) -> MenuRelationship {
        var menu: Int?
        for element in node.linkedElements {
            // Missing references may be menus being rebuilt. Do not discard
            // them and authorize a different menu from partial evidence.
            guard let at = index(of: element, nodes: nodes) else { return .unavailable }
            guard nodes[at].role == "AXMenu" else { continue }
            guard menu == nil || menu == at else { return .unavailable }
            menu = at
        }
        // Resolved non-menu references (including flow-to) are not menu claims.
        guard let menu else { return .noMenu }
        guard nodes[menu].rect.width > 0, nodes[menu].rect.height > 0 else { return .unavailable }
        return .menu(menu)
    }

    // AXTitleUIElement and AXLinkedUIElements are REFERENCES, not children.
    // Resolve only nodes already present in this complete native capture. Never
    // walk those edges recursively or import a label from another WebArea/panel.
    private func scope(of index: Int, nodes: [AXNode]) -> Int? {
        var current: Int? = index, visited = Set<Int>()
        for _ in 0..<80 {
            guard let at = current, nodes.indices.contains(at), visited.insert(at).inserted else { return nil }
            let node = nodes[at]
            if node.identifier.hasPrefix("app-shell-tab-panel-") ||
                ["AXWindow", "AXWebArea", "AXMenu"].contains(node.role) { return at }
            current = node.parent
        }
        return nil
    }

    private func titleStrings(for source: Int, nodes: [AXNode]) -> [String] {
        guard let element = nodes[source].titleElement,
              let label = index(of: element, nodes: nodes), label != source,
              let owner = scope(of: source, nodes: nodes), scope(of: label, nodes: nodes) == owner else { return [] }
        var pending = [label], cursor = 0, visited = Set<Int>(), result: [String] = []
        let labelRoles = ["AXStaticText", "AXGroup", "AXHeading", "AXImage"]
        while cursor < pending.count {
            // Oversized/invalid relationships confer no partial label evidence.
            guard cursor < 64 else { return [] }
            let at = pending[cursor]; cursor += 1
            guard nodes.indices.contains(at), visited.insert(at).inserted else { continue }
            guard scope(of: at, nodes: nodes) == owner,
                  labelRoles.contains(nodes[at].role) else { continue }
            result.append(contentsOf: nodes[at].accessibleStrings)
            pending.append(contentsOf: children[at] ?? [])
        }
        return Array(Set(result.filter { !$0.isEmpty })).sorted()
    }

    func resolvingRelationships(in nodes: [AXNode]) -> [AXNode] {
        var resolved = nodes
        for at in nodes.indices {
            let node = nodes[at]
            if node.button || ["AXMenuItem", "AXRadioButton", "AXCheckBox"].contains(node.role) {
                let labels = titleStrings(for: at, nodes: nodes)
                if !labels.isEmpty {
                    resolved[at].accessibleStrings = Array(Set(node.accessibleStrings + labels)).sorted()
                    if node.name.isEmpty, labels.count == 1 { resolved[at].name = labels[0] }
                    resolved[at].titleRelationshipResolved = true
                }
            }
            // Undefined AXExpanded is not false. Require a native menu popup
            // plus a unique visible linked menu, not merely any linked element.
            // AXLinkedUIElements can also represent flow-to relationships.
            // Explicit false wins; absent/ambiguous evidence remains nil.
            if node.button, node.expanded == nil,
               node.popupValue == "menu" || node.role == "AXPopUpButton" {
                if case .menu = linkedMenu(for: node, nodes: nodes) {
                    resolved[at].expanded = true
                    resolved[at].expandedFromLinkedMenu = true
                }
            }
        }
        return resolved
    }

    func strings(under index: Int, nodes: [AXNode]) -> [String] {
        var pending = [index], cursor = 0, strings: [String] = []
        while cursor < pending.count, cursor < nodes.count {
            let at = pending[cursor]; cursor += 1
            strings.append(contentsOf: nodes[at].accessibleStrings)
            pending.append(contentsOf: children[at] ?? [])
        }
        return strings
    }
}
