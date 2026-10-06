import AppKit
import ApplicationServices
import CryptoKit
import MicroCore
import MicroShared

// AX work stays on the UI adapter's serial queue. No windows, titles, or
// compositor coordinates are accepted as authority for an existing chat ID.
enum MacAX {
    static func value(_ element: AXUIElement, _ key: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    static func element(_ value: Any?) -> AXUIElement? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func same(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return CFEqual(lhs, rhs)
    }
    static func set(_ element: AXUIElement, _ key: String, _ value: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(element, key as CFString, value) == .success else {
            throw CodexClientError.unavailable("The native control did not accept the action.")
        }
    }
    static func press(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw CodexClientError.outcomeUnknown
        }
    }
    static func applicationCommand(pid:Int32,names:[String],context:UIRequestContext) throws -> AXNode? {
        let app=AXUIElementCreateApplication(pid)
        guard let bar=element(value(app,"AXMenuBar")) else { return nil }
        var pending=[(bar,0)],index=0,matches:[AXNode]=[]
        while index < pending.count {
            try context.check()
            guard index < 1500 else { throw CodexClientError.unavailable("The application menu is incomplete.") }
            let (element,depth)=pending[index];index += 1
            let node=AXNode(element,parent:nil)
            if node.role == "AXMenuItem",node.enabled,node.named(names) {matches.append(node)}
            guard depth < 12 || node.children.isEmpty else { throw CodexClientError.unavailable("The application menu is incomplete.") }
            pending.append(contentsOf:node.children.map{($0,depth+1)})
        }
        return matches.count == 1 ? matches[0]:nil
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

final class UIRequestContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime > deadline { throw CodexClientError.unavailable("Native control timed out.") }
    }
}

struct AXNode {
    let element: AXUIElement
    let parent: Int?
    let role: String
    let subrole: String
    let name: String
    let identifier: String
    let classes: [String]
    let url: String
    let documentURLs: [String]
    let current: Bool
    let enabled: Bool
    let focused: Bool
    let expanded: Bool?
    let selected: Bool
    let rect: CGRect
    let text: String?
    let selectedTextRange: NSRange?
    let numericValue: Double?
    let accessibleStrings: [String]
    let minimum: Double?
    let maximum: Double?
    let valueSettable: Bool
    let children: [AXUIElement]

    init(_ element: AXUIElement, parent: Int?) {
        self.element = element; self.parent = parent
        let keys = ["AXRole", "AXTitle", "AXDescription", "AXDOMIdentifier", "AXDOMClassList", "AXURL", "AXARIACurrent",
                    "AXEnabled", "AXFocused", "AXExpanded", "AXSelected", "AXPosition", "AXSize", "AXValue", "AXChildren", "AXSubrole", "AXHelp", "AXValueDescription", "AXMinValue", "AXMaxValue", "AXSelectedTextRange"]
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values)
        let array = status == .success ? values as? [Any] ?? [] : []
        func v(_ index: Int) -> Any? { array.indices.contains(index) && !(array[index] is NSNull) ? array[index] : nil }
        role = v(0) as? String ?? ""
        subrole = v(15) as? String ?? ""
        name = (v(1) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? v(2) as? String ?? ""
        identifier = v(3) as? String ?? ""; classes = v(4) as? [String] ?? []
        func address(_ value: Any?) -> String? {
            let text = (value as? URL)?.absoluteString ?? value as? String
            return text.flatMap { $0.isEmpty ? nil : $0 }
        }
        // Chromium versions differ in which document attribute tracks SPA
        // navigation. Keep all live evidence so stale/conflicting attributes
        // cannot silently pick a different thread.
        documentURLs = role == "AXWebArea" ? [v(5),v(13),MacAX.value(element,"AXDocument")].compactMap(address) : []
        url = address(v(5)) ?? ""
        current = ["page", "true"].contains(v(6) as? String ?? "") || v(6) as? Bool == true
        enabled = v(7) as? Bool ?? true; focused = v(8) as? Bool ?? false
        expanded = v(9) as? Bool; selected = (v(10) as? Bool ?? false) || (["AXRadioButton","AXCheckBox"].contains(role) && (v(13) as? NSNumber)?.intValue == 1)
        var origin = CGPoint.zero, size = CGSize.zero
        if let raw = v(11), CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() { _ = AXValueGetValue(raw as! AXValue, .cgPoint, &origin) }
        if let raw = v(12), CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() { _ = AXValueGetValue(raw as! AXValue, .cgSize, &size) }
        rect = CGRect(origin: origin, size: size)
        text = ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) ? v(13) as? String : nil
        var range=CFRange(location:0,length:0)
        if let raw=v(keys.firstIndex(of:"AXSelectedTextRange")!),CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID(),
           AXValueGetType(raw as! AXValue) == .cfRange,AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location >= 0,range.length >= 0 {
            selectedTextRange=NSRange(location:range.location,length:range.length)
        } else {selectedTextRange=nil}
        numericValue = (v(13) as? NSNumber)?.doubleValue
        accessibleStrings = Array(Set([name,v(1) as? String,v(2) as? String,v(13) as? String,
            v(16) as? String,v(17) as? String].compactMap { $0 }.filter { !$0.isEmpty })).sorted()
        minimum = (v(18) as? NSNumber)?.doubleValue
        maximum = (v(19) as? NSNumber)?.doubleValue
        var settable = DarwinBoolean(false)
        valueSettable = role == "AXSlider" && AXUIElementIsAttributeSettable(element,"AXValue" as CFString,&settable) == .success && settable.boolValue
        children = v(14) as? [AXUIElement] ?? []
    }
    init(element:AXUIElement, parent:Int? = nil, role:String = "AXButton", name:String = "", identifier:String = "", strings:[String] = [], enabled:Bool = true, expanded:Bool? = nil, selected:Bool = false, focused:Bool = false, text:String? = nil, selectedTextRange:NSRange? = nil, minimum:Double? = nil, maximum:Double? = nil, valueSettable:Bool = false, classes:[String] = [], frame:CGRect = CGRect(x:0,y:0,width:100,height:100), url:String="",documentURLs:[String]=[],current:Bool=false) {
        self.element=element; self.parent=parent; self.role=role; self.name=name; self.identifier=identifier
        self.accessibleStrings=Array(Set([name]+strings)).filter { !$0.isEmpty }.sorted()
        self.expanded=expanded; self.selected=selected; self.focused=focused; self.text=text
        self.selectedTextRange=selectedTextRange
        self.minimum=minimum; self.maximum=maximum; self.valueSettable=valueSettable
        subrole=""; self.classes=classes; self.url=url; self.documentURLs=documentURLs; self.current=current; self.enabled=enabled
        rect=frame; numericValue=nil; children=[]
    }
    func named(_ names: [String]) -> Bool { names.contains { $0.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } }
    var button: Bool { ["AXButton", "AXPopUpButton", "AXComboBox"].contains(role) }
}

struct MacUISnapshot {
    let app: NSRunningApplication
    let root: AXUIElement
    let window: AXUIElement
    let nodes: [AXNode]
    let composer: Int?
    let container: Int?
    let thread: String?
    let draft: Bool
    let route: String?
    let selectionKnown: Bool
    let nativeFallback: Bool
    let selectedSidebar: AXUIElement?
    let controls: [Int]
    let menuItems: [Int]
    let blocked: Bool
    let modelLabels: [String]
    var clientBinding:ClientRoutePair? = nil
    var bindingVerified=false
    var treeIndex: AXTreeIndex?
    var composerCandidates = 0
    var pickerCandidates = 0
    var pickerSource = "none"
    var captureDuration: TimeInterval = 0
    var observedAtUptime = ProcessInfo.processInfo.systemUptime
    var routeEvidence = "native-window"

    static let sendNames = ["Send", "Send message", "发送", "发送消息", "傳送", "傳送訊息"]
    static let stopNames = ["Stop", "Stop generating", "停止", "停止生成"]
    static let sidebarOpenNames = ["Hide sidebar", "Close sidebar", "隐藏侧栏", "关闭侧栏", "隐藏侧边栏", "关闭侧边栏", "隱藏側邊欄", "關閉側邊欄"]
    static let sidebarClosedNames = ["Show sidebar", "显示侧栏", "显示侧边栏", "顯示側邊欄"]
    static let sidebarNames = sidebarOpenNames + sidebarClosedNames + ["Toggle sidebar", "切换侧栏", "切换侧边栏", "切換側邊欄"]
    static let addNames = ["Add files and more", "添加文件等内容", "新增檔案和更多內容", "加入檔案及更多內容"]
    static let sketchNames = ["Sketch", "Sketch Draw a sketch", "绘图", "绘图 绘制草图", "繪圖", "繪圖 繪製草圖"]
    static let sketchCloseNames = ["Close sketch editor", "关闭草图编辑器", "關閉草圖編輯器"]
    static let modelPickerNames = ["Select model", "Select ChatGPT model", "选择模型", "选择 ChatGPT 模型", "選擇模型", "選取模型", "選擇 ChatGPT 模型", "選取 ChatGPT 模型"]
    static let effortPickerNames = ["Select effort", "选择强度", "选择推理强度", "選擇推理強度", "選取推理強度"]
    static let pickerNames = modelPickerNames + effortPickerNames
    static let planNames = ["Plan", "计划", "方案", "規劃", "計劃"]
    static let planMenuNames = planNames + ["Plan mode", "计划模式", "計劃模式", "規劃模式"]
    static let voiceNames = ["Dictate", "Start dictation", "语音输入", "听写", "聽寫"]
    static let voiceStopNames = ["Stop dictation", "停止听写", "停止聽寫"]

    static func capture(context: UIRequestContext, permitMicro: Bool = true, permitBackground: Bool = false, modelLabels: [String] = []) throws -> MacUISnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        try context.check()
        guard AXIsProcessTrusted() else { throw NativeObservationFailure.accessibilityRequired }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard !apps.isEmpty else { throw NativeObservationFailure.applicationUnavailable }
        guard apps.count == 1, let app = apps.first, !app.isTerminated else {
            throw NativeObservationFailure.applicationAmbiguous
        }
        let front = NSWorkspace.shared.frontmostApplication
        guard permitBackground || front?.processIdentifier == app.processIdentifier || (permitMicro && front?.processIdentifier == getpid()) else {
            throw NativeObservationFailure.foregroundRequired
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = MacAX.element(MacAX.value(root, "AXFocusedWindow")) ?? MacAX.element(MacAX.value(root, "AXMainWindow")) else { throw NativeObservationFailure.windowUnavailable }
        guard MacAX.value(window, "AXMinimized") as? Bool != true else { throw NativeObservationFailure.windowMinimized }
        var nodes: [AXNode] = [], pending: [(AXUIElement, Int?)] = [(window, nil)], index = 0
        // Electron native context menus can be app children outside WebArea.
        // Include only menu roots, never another app window.
        for child in MacAX.value(root,"AXChildren") as? [AXUIElement] ?? [] {
            if MacAX.value(child,"AXRole") as? String == "AXMenu" { pending.append((child,nil)) }
        }
        var seen:[CFHashCode:[AXUIElement]]=[:]
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while index < pending.count {
            try context.check()
            guard nodes.count < 6000, ProcessInfo.processInfo.systemUptime < deadline else { throw NativeObservationFailure.treeIncomplete }
            let (element, parent) = pending[index]; index += 1
            let hash=CFHash(element)
            if seen[hash]?.contains(where:{MacAX.same($0,element)}) == true { continue }
            seen[hash,default:[]].append(element)
            let node = AXNode(element, parent: parent), own = nodes.count
            nodes.append(node)
            // Embedded browser/editor web areas cannot contribute targets.
            let nestedWebArea = node.role == "AXWebArea" && Self.hasAncestor(own, nodes: nodes, matching: { $0.role == "AXWebArea" })
            if !nestedWebArea { pending.append(contentsOf: node.children.map { ($0, own) }) }
        }
        try context.check()
        let visible = nodes.indices.filter { nodes[$0].rect.width > 0 && nodes[$0].rect.height > 0 }
        let tree = AXTreeIndex(nodes)
        let scope = NativeComposerScope(nodes: nodes, tree: tree, modelLabels: modelLabels)
        let composer = scope.composer, container = scope.container, controls = scope.controls
        let active = visible.filter { nodes[$0].current && nodes[$0].classes.contains("sidebar-item") }
        let liveDocuments = visible.filter { nodes[$0].role == "AXWebArea" &&
            !Self.hasAncestor($0,nodes:nodes,matching:{$0.role == "AXWebArea"}) }.flatMap { nodes[$0].documentURLs }
        let fallbackDocument = composer == nil || container == nil || liveDocuments.contains(where: { CurrentRoute.documentPath($0) != nil }) ? nil :
            DesktopRouteObservation.document(app:app,root:root,window:window)
        let route = Self.observeRoute(nodes:nodes,composer:composer,container:container,controls:controls,
            fallbackDocument:fallbackDocument,modelLabels:modelLabels)
        let menuItems = visible.filter { nodes[$0].enabled && ["AXMenuItem", "AXRadioButton", "AXCheckBox"].contains(nodes[$0].role) && Self.hasAncestor($0, nodes: nodes, matching: { ["AXMenu", "AXList", "AXListBox"].contains($0.role) }) }
        let blocked = visible.contains { nodes[$0].role == "AXSheet" || nodes[$0].role == "AXDialog" || nodes[$0].subrole == "AXDialog" }
        var snapshot = Self(app: app, root: root, window: window, nodes: nodes, composer: composer, container: container,
            thread: route.threadID, draft: route.draft, route: route.key, selectionKnown: route.known,
            nativeFallback: route.allowsNativeComposer(selectedSidebarCount: active.count),
            selectedSidebar: active.count == 1 ? nodes[active[0]].element : nil,
            controls: controls, menuItems: menuItems, blocked: blocked, modelLabels: modelLabels,clientBinding:route.pendingBinding)
        snapshot.treeIndex = tree; snapshot.composerCandidates = scope.candidateCount
        snapshot.pickerCandidates = scope.pickerCandidateCount; snapshot.pickerSource = scope.pickerSource
        snapshot.captureDuration = ProcessInfo.processInfo.systemUptime - started
        snapshot.routeEvidence = fallbackDocument != nil ? "desktop-window-log" : liveDocuments.contains(where:{CurrentRoute.documentPath($0) != nil}) ? "native-document" : "native-sidebar-or-home"
        try context.check()
        let currentWindow = MacAX.element(MacAX.value(root,"AXFocusedWindow")) ?? MacAX.element(MacAX.value(root,"AXMainWindow"))
        guard !app.isTerminated, MacAX.same(window,currentWindow) else { throw NativeObservationFailure.windowChanged }
        return snapshot
    }
    static func observeRoute(nodes:[AXNode],composer:Int?,container:Int?,controls:[Int]?=nil,fallbackDocument:String?=nil,modelLabels:[String]=[])->CurrentRoute {
        let visible=nodes.indices.filter {nodes[$0].rect.width > 0 && nodes[$0].rect.height > 0}
        let active=visible.filter {nodes[$0].current && nodes[$0].classes.contains("sidebar-item")}
        var documents=visible.filter {nodes[$0].role == "AXWebArea" && !hasAncestor($0,nodes:nodes,matching:{$0.role == "AXWebArea"})}.flatMap {nodes[$0].documentURLs}
        if !documents.contains(where:{CurrentRoute.documentPath($0) != nil}),let fallbackDocument {documents.append(fallbackDocument)}
        let home=homeComposerEvidence(nodes:nodes,composer:composer,container:container,controls:controls,modelLabels:modelLabels) != nil
        return CurrentRoute.resolve(documents:documents,selectedLinks:active.map {nodes[$0].url},homeComposer:home,composerAvailable:composer != nil && container != nil)
    }
    static func homeComposerEvidence(nodes:[AXNode],composer:Int?,container:Int?,controls scopedControls:[Int]?=nil,modelLabels:[String])->String? {
        guard let composer,nodes.indices.contains(composer) else {return nil}
        let marker="[container-name:home-main-content]"
        if hasAncestor(composer,nodes:nodes,matching:{$0.classes.contains(marker)}) {return "ancestor"}
        // Codex can render the footer composer beside its home main content.
        // Require both in one native WebArea and the complete composer controls;
        // a browser/side-chat panel or a merely visible home marker is insufficient.
        guard let container,nodes.indices.contains(container),nodes[composer].text != nil,
              !hasAncestor(composer,nodes:nodes,matching:{$0.identifier.hasPrefix("app-shell-tab-panel-")}) else {return nil}
        let areas=nodes.indices.filter {nodes[$0].role == "AXWebArea" && within(composer,ancestor:$0,nodes:nodes)}
        guard areas.count == 1,let area=areas.first,within(container,ancestor:area,nodes:nodes),
              nodes[area].documentURLs.contains(where:{ value in
                  guard let url=URLComponents(string:value) else {return false}
                  return url.scheme == "app" && url.host == "-" && url.user == nil && url.password == nil && url.port == nil
              }) else {return nil}
        let homes=nodes.indices.filter {nodes[$0].rect.width > 0 && nodes[$0].rect.height > 0 &&
            nodes[$0].classes.contains(marker) && within($0,ancestor:area,nodes:nodes) &&
            !hasAncestor($0,nodes:nodes,matching:{$0.role == "AXWebArea" && !MacAX.same($0.element,nodes[area].element)})}
        guard homes.count == 1 else {return nil}
        let controls=(scopedControls ?? nodes.indices.filter {nodes[$0].enabled && nodes[$0].button && nodes[$0].rect.width > 0 &&
            nodes[$0].rect.height > 0 && within($0,ancestor:container,nodes:nodes)}).filter { index in
                nodes.indices.contains(index) && nodes[index].enabled && nodes[index].rect.width > 0 && nodes[index].rect.height > 0 &&
                    (within(index,ancestor:area,nodes:nodes) || index == area) &&
                    !hasAncestor(index,nodes:nodes,matching:{$0.role == "AXWebArea" && !MacAX.same($0.element,nodes[area].element)})
            }
        guard controls.contains(where:{nodes[$0].named(sendNames+stopNames+addNames)}) else {return nil}
        let pickers=controls.filter {index in
            let texts=nodes.indices.filter {$0 == index || within($0,ancestor:index,nodes:nodes)}.flatMap {nodes[$0].accessibleStrings}
            return matchesPicker(texts,modelLabels:modelLabels)
        }
        return pickers.count == 1 ? "shell-footer":nil
    }
    static func within(_ index: Int, ancestor: Int, nodes: [AXNode]) -> Bool {
        var parent = nodes[index].parent
        for _ in 0..<80 { guard let at = parent else { return false }; if at == ancestor { return true }; parent = nodes[at].parent }
        return false
    }
    static func hasAncestor(_ index: Int, nodes: [AXNode], matching: (AXNode) -> Bool) -> Bool {
        var parent = nodes[index].parent
        for _ in 0..<80 { guard let at = parent else { return false }; if matching(nodes[at]) { return true }; parent = nodes[at].parent }
        return false
    }
    static func threadID(_ value: String) -> String? {
        CurrentRoute.sidebarThread(value)
    }
    func unique(_ indexes: [Int], matching: (AXNode) -> Bool) -> AXNode? {
        let matches = indexes.filter { matching(nodes[$0]) }; return matches.count == 1 ? nodes[matches[0]] : nil
    }
    var editor: AXNode? { composer.map { nodes[$0] } }
    func strings(under element:AXUIElement) -> [String] {
        if let treeIndex, let index = treeIndex.index(of:element,nodes:nodes) { return treeIndex.strings(under:index,nodes:nodes) }
        guard let index=nodes.firstIndex(where:{MacAX.same($0.element,element)}) else { return [] }
        return nodes.indices.filter { $0 == index || Self.within($0,ancestor:index,nodes:nodes) }.flatMap { nodes[$0].accessibleStrings }
    }
    var picker: AXNode? {
        unique(controls) { node in
            node.enabled && Self.matchesPicker(strings(under:node.element),modelLabels:modelLabels)
        }
    }
    static func matchesPicker(_ texts:[String],modelLabels:[String])->Bool {
        // AXTitle may contain only the visible model/power value while the
        // stable aria-label is exposed as AXDescription or AXHelp.
        texts.contains { text in pickerNames.contains { $0.caseInsensitiveCompare(text.trimmingCharacters(in:.whitespacesAndNewlines)) == .orderedSame } } ||
            modelLabels.contains { label in texts.contains { MacUIController.prefix($0,label) } }
    }
    var modelSubmenu: AXNode? {
        unique(menuItems) { node in
            node.enabled && strings(under: node.element).contains { text in
                Self.modelPickerNames.contains { $0.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
            }
        }
    }
    var modelMenu: Int? {
        guard picker?.expanded == true else { return nil }
        let candidates=nodes.indices.filter { nodes[$0].role == "AXMenu" &&
            !Self.hasAncestor($0,nodes:nodes,matching:{$0.role == "AXMenu"}) }
        return candidates.count == 1 ? candidates[0] : nil
    }
    var powerTexts: [String] {
        guard let menu=modelMenu else { return [] }
        let texts=strings(under:nodes[menu].element)
        return texts.contains(where:{ text in NativeComposerSelection.powerNames.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) }) ? texts : []
    }
    var powerSlider: AXNode? {
        guard let menu=modelMenu, !powerTexts.isEmpty else { return nil }
        return unique(nodes.indices.filter { Self.within($0,ancestor:menu,nodes:nodes) }) { $0.role == "AXSlider" && $0.enabled }
    }
    var send: AXNode? { unique(controls) { $0.enabled && $0.named(Self.sendNames) } }
    var composerMenuItems: [Int] {
        guard unique(controls,matching:{$0.named(Self.addNames) && $0.expanded == true}) != nil else { return [] }
        return nodes.indices.filter { index in
            let node=nodes[index]
            return node.enabled && ["AXMenuItem","AXRadioButton","AXCheckBox","AXRow","AXButton"].contains(node.role) &&
                Self.hasAncestor(index,nodes:nodes,matching:{["AXMenu","AXList","AXListBox"].contains($0.role)})
        }
    }
    var sketchOpen: Bool { nodes.contains { $0.enabled && $0.button && $0.named(Self.sketchCloseNames) } }
    var reviewOpen: Bool { nodes.contains { ["AXRadioButton", "AXTab", "AXButton"].contains($0.role) && $0.selected && $0.named(["Review", "审查", "审阅"]) } }
    var visibleTerminalCount:Int {
        // xterm's helper textarea intentionally has zero size and lives off
        // screen. Visibility belongs to its app-shell tab panel, not the input.
        nodes.indices.filter { panel in
            nodes[panel].identifier.hasPrefix("app-shell-tab-panel-") && nodes[panel].rect.width > 0 && nodes[panel].rect.height > 0 &&
                nodes.indices.contains { nodes[$0].classes.contains("xterm-helper-textarea") && Self.within($0,ancestor:panel,nodes:nodes) }
        }.count
    }
    var browserPanels:[AXNode] {
        let names=["Search or enter a URL","搜索或输入网址","搜尋或輸入網址"]
        return nodes.indices.filter { panel in
            nodes[panel].identifier.hasPrefix("app-shell-tab-panel-") && nodes.indices.contains { index in
                ["AXTextField","AXComboBox"].contains(nodes[index].role) && nodes[index].named(names) && Self.within(index,ancestor:panel,nodes:nodes) &&
                !Self.hasAncestor(index,nodes:nodes,matching:{ $0.role == "AXWebArea" && !$0.documentURLs.contains(where:{CurrentRoute.documentPath($0) != nil}) })
            }
        }.map { nodes[$0] }
    }
    var plan: Bool { controls.contains { nodes[$0].named(Self.planNames) } }
    var settings: [String: Any] { ["picker": picker.map { strings(under:$0.element) } ?? [], "power":powerTexts, "plan": plan] }
    var clientThreadID:String? {bindingVerified ? clientBinding?.clientThreadID:CurrentRoute.clientThreadID(routeKey:route)}
    var nativeComposer: Bool {
        (clientThreadID != nil || nativeFallback && selectedSidebar != nil && picker != nil) && editor?.text != nil && !blocked
    }
    func sameObservedTarget(_ other: MacUISnapshot) -> Bool {
        guard app.processIdentifier == other.app.processIdentifier, MacAX.same(window, other.window) else { return false }
        if let route { return route != "conflict" && route == other.route && clientBinding == other.clientBinding }
        return other.route == nil && nativeComposer && other.nativeComposer &&
            MacAX.same(selectedSidebar, other.selectedSidebar) && MacAX.same(editor?.element, other.editor?.element)
    }
    func sameTarget(_ other: MacUISnapshot, text: Bool = false) -> Bool {
        let sameIdentity = route != nil && route == other.route ||
            (route == nil && other.route == nil && nativeComposer && other.nativeComposer && MacAX.same(selectedSidebar, other.selectedSidebar) && MacAX.same(picker?.element, other.picker?.element))
        return app.processIdentifier == other.app.processIdentifier && MacAX.same(window, other.window) && sameIdentity &&
        MacAX.same(editor?.element, other.editor?.element) && (!text || editor?.text == other.editor?.text)
    }
}
