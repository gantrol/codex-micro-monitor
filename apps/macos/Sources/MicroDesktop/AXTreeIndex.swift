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
