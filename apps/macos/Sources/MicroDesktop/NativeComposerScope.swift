import Foundation

/// The complete-tree observer and the focused-element fallback use the same
/// ancestry rule. Window geometry and labels outside this scope confer no authority.
struct NativeComposerScope {
    struct Ancestor {
        let role: String
        let identifier: String
    }
    static func allows(_ ancestors: [Ancestor]) -> Bool {
        !ancestors.contains { $0.identifier.hasPrefix("app-shell-tab-panel-") || ["AXMenu", "AXMenuBar"].contains($0.role) } &&
            ancestors.filter { $0.role == "AXWebArea" }.count <= 1
    }

    let composer: Int?
    let container: Int?
    let controls: [Int]
    let candidateCount: Int
    let pickerCandidateCount: Int
    let pickerSource: String

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
        func webArea(_ index: Int) -> Int? {
            var current: Int? = index
            for _ in 0..<80 {
                guard let at = current, nodes.indices.contains(at) else { return nil }
                if nodes[at].role == "AXWebArea" { return at }
                current = nodes[at].parent
            }
            return nil
        }
        func pickerTexts(_ index: Int) -> [String] {
            tree.strings(under: index, nodes: nodes)
        }
        func gap(_ first: CGRect, _ second: CGRect) -> CGFloat {
            let horizontal = max(0, max(first.minX - second.maxX, second.minX - first.maxX))
            let vertical = max(0, max(first.minY - second.maxY, second.minY - first.maxY))
            return hypot(horizontal, vertical)
        }
        func ancestryDistance(_ first: Int, _ second: Int) -> Int {
            var distances: [Int: Int] = [first: 0], current = nodes[first].parent, depth = 1
            for _ in 0..<80 {
                guard let at = current, nodes.indices.contains(at) else { break }
                distances[at] = depth; depth += 1; current = nodes[at].parent
            }
            current = second; depth = 0
            for _ in 0..<80 {
                guard let at = current, nodes.indices.contains(at) else { break }
                if let firstDepth = distances[at] { return firstDepth + depth }
                depth += 1; current = nodes[at].parent
            }
            return Int.max
        }
        let candidates = nodes.indices.filter {
            nodes[$0].enabled && nodes[$0].rect.width > 0 && nodes[$0].rect.height > 0 &&
                ["AXTextArea", "AXTextField"].contains(nodes[$0].role) &&
                nodes[$0].classes.contains("ProseMirror") && belongsToMainComposer($0)
        }
        candidateCount = candidates.count
        composer = candidates.count == 1 ? candidates[0] : nil
        var foundContainer: Int?, foundControls: [Int] = []
        var foundPickerCandidates = 0, foundPickerSource = "none"
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
            let localPickers = foundControls.filter {
                MacUISnapshot.matchesPicker(pickerTexts($0), modelLabels: modelLabels)
            }
            foundPickerCandidates = localPickers.count
            if localPickers.count == 1 {
                foundPickerSource = "composer-container"
            } else if localPickers.isEmpty, foundContainer != nil, let area = webArea(composer) {
                // Chromium can expose the intelligence trigger beside the
                // composer branch instead of below the action-row ancestor.
                // Search only the same top-level WebArea and retain the input
                // geometry as authority; a page/header label alone is never
                // enough to obtain a native settings target.
                let anchor = foundControls.filter {
                    nodes[$0].named(MacUISnapshot.sendNames + MacUISnapshot.stopNames + MacUISnapshot.addNames)
                }.reduce(nodes[composer].rect) { $0.union(nodes[$1].rect) }
                let nearby = nodes.indices.filter { index in
                    let node = nodes[index]
                    guard node.enabled, node.rect.width > 0, node.rect.height > 0,
                          node.rect.height <= 120, node.rect.width <= max(anchor.width + 240, 360),
                          // A closed popup need not publish AXExpanded. Its
                          // actionable role, popup semantics and label remain
                          // required; an expanded AXGroup is not a press target.
                          node.button,
                          (node.expanded != nil || node.popupValue == "menu" || node.role == "AXPopUpButton"),
                          belongsToMainComposer(index),
                          webArea(index) == area,
                          MacUISnapshot.matchesPicker(pickerTexts(index), modelLabels: modelLabels) else { return false }
                    let horizontal = max(0, max(anchor.minX - node.rect.maxX, node.rect.minX - anchor.maxX))
                    let vertical = max(0, max(anchor.minY - node.rect.maxY, node.rect.minY - anchor.maxY))
                    return horizontal <= 200 && vertical <= 240
                }
                foundPickerCandidates = nearby.count
                let ranked = nearby.map { index -> (index: Int, score: Double, area: CGFloat) in
                    let texts = pickerTexts(index)
                    let stableLabel = texts.contains { text in
                        MacUISnapshot.pickerNames.contains {
                            $0.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                        }
                    }
                    var score = stableLabel ? 200.0 : 100.0
                    if nodes[index].button { score += 40 }
                    if nodes[index].expanded != nil { score += 30 }
                    score += Double(max(0, 40 - min(40, ancestryDistance(composer, index))))
                    score -= Double(gap(anchor, nodes[index].rect)) / 10
                    return (index, score, nodes[index].rect.width * nodes[index].rect.height)
                }.sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.area < $1.area
                }
                if let best = ranked.first,
                   ranked.count == 1 || best.score > ranked[1].score + 0.5 {
                    if !foundControls.contains(best.index) { foundControls.append(best.index) }
                    foundPickerSource = "composer-web-area"
                } else if !ranked.isEmpty {
                    foundPickerSource = "ambiguous"
                }
            } else if localPickers.count > 1 {
                foundPickerSource = "ambiguous"
            }
        }
        container = foundContainer
        controls = foundControls
        pickerCandidateCount = foundPickerCandidates
        pickerSource = foundPickerSource
    }
}
