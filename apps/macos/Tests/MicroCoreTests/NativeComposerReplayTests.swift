import XCTest
import AppKit
import ApplicationServices
@testable import MicroDesktop
@testable import MicroCore
@testable import MicroPanelModel

/// OS effects only are replaced. No Accessibility call reads or controls Codex.
/// Replay the actual controller, including capture leases, focus and readback.
private final class NativeTraceRig: @unchecked Sendable {
    static let models:[[String:Any]] = [
        ["model":"gpt-6.1-sol","displayName":"GPT-6.1-sol","supportedReasoningEfforts":["low","medium","high","xhigh"].map {["reasoningEffort":$0]},"defaultReasoningEffort":"medium"],
        ["model":"gpt-6-luna","displayName":"GPT-6-luna","supportedReasoningEfforts":["low","high"].map {["reasoningEffort":$0]},"defaultReasoningEffort":"low"]
    ]
    let elements=(0..<30).map { AXUIElementCreateApplication(Int32(500000+$0)) }
    var model="gpt-6.1-sol",effort="medium",speed=NativeComposerSelection.Speed.standard
    var menu=false,speedMenu=false,addMenu=false,plan=false,generic=true,slider=false,blocked=false,changed=false
    var contradictoryPower=false,missingPlan=false,chinese=false,hideModelRows=false,modelSubmenu=false,closeOnModel=false,closeOnSpeed=false
    var focus:String?
    var frontPID:Int32?=NSRunningApplication.current.processIdentifier
    var planList=false
    var documentURL:String?
    var selectedLinks:[String]=[]
    var homeMarker=false
    var commands:[String:MacShortcut]=[:]
    var events:[String]=[]
    var onFocus:(()->Void)?
    var onModel:(()->Void)?
    var efforts:[String] { model == "gpt-6.1-sol" ? ["low","medium","high","xhigh"] : ["low","high"] }
    var label:String { model.replacingOccurrences(of:"gpt-",with:"") }
    var access:NativeUIAccess {
        var io=NativeUIAccess()
        io.observeActivation=false
        io.foreground={ [self] in frontPID }
        io.capture={ [self] _,_ in snapshot() }
        io.activate={ _ in XCTFail("Replay must not activate any app"); return false }
        io.shortcut={ [self] command in guard let value=commands[command] else { throw CodexClientError.unavailable("fixture has no configured binding") }; return value }
        io.press={ [self] element in
            let name=identity(element);events.append("press:"+name)
            switch name {
            case "picker":menu=true
            case "add":addMenu=true
            case "plan":plan.toggle();addMenu=false
            case "speed":speedMenu=true
            case "model-a":model="gpt-6.1-sol";effort="medium";modelSubmenu=false;if closeOnModel {menu=false};onModel?()
            case "model-b":model="gpt-6-luna";effort="low";modelSubmenu=false;if closeOnModel {menu=false};onModel?()
            case "select-model":modelSubmenu=true
            case "standard","fast","ultrafast":speed=NativeComposerSelection.Speed(rawValue:name)!;speedMenu=false;if closeOnSpeed {menu=false}
            default:XCTFail("Unexpected press: "+name)
            }
        }
        io.set={ [self] element,attribute,value in
            let name=identity(element)
            if attribute == "AXFocused" { events.append("focus:"+name);focus=name;onFocus?() }
            else if attribute == "AXValue",name == "slider",let number=value as? NSNumber {
                events.append("range:"+number.stringValue);effort=efforts[Int(number.doubleValue.rounded())]
            } else { XCTFail("Unexpected setting") }
        }
        io.send={ [self] key,_,check in
            try check();events.append("key:\(key.key)@\(focus ?? "none")")
            switch key.key {
            case 53:menu=false;speedMenu=false;addMenu=false;focus=nil
            case 124,123:
                XCTAssertEqual(focus,"power");let at=efforts.firstIndex(of:effort)!
                effort=efforts[max(0,min(efforts.count-1,at+(key.key == 124 ? 1:-1)))]
            case 96:XCTAssertEqual(focus,"editor");plan.toggle()
            case 97:speed = speed == .standard ? .fast : speed == .fast ? .ultrafast : .standard
            default:XCTFail("Unexpected shortcut")
            }
        }
        return io
    }
    func identity(_ element:AXUIElement) -> String {
        let index=elements.firstIndex(where:{CFEqual($0,element)})!
        return [2:"editor",3:"picker",5:"add",6:"send",7:"plan",9:"power",10:"speed",11:"model-a",12:"model-b",14:"standard",15:"fast",16:"ultrafast",18:"slider",19:"select-model",21:"plan"][index] ?? "node-\(index)"
    }
    func snapshot() -> MacUISnapshot {
        func node(_ id:Int,_ parent:Int?,_ role:String,_ name:String,strings:[String]=[],expanded:Bool?=nil,selected:Bool=false) -> AXNode {
            AXNode(element:elements[id],parent:parent,role:role,name:name,identifier:"node-\(id)",strings:strings,expanded:expanded,selected:selected,focused:focus == identity(elements[id]))
        }
        var nodes=[node(0,nil,"AXWindow","fixture"),node(1,0,"AXGroup","home"),
            AXNode(element:elements[2],parent:1,role:"AXTextArea",focused:focus == "editor",text:"fixture prompt"),
            node(3,1,"AXButton","Select model",expanded:menu),
            node(4,3,"AXStaticText",generic ? "" : "\(label) \(effort)"),
            node(5,1,"AXButton","Add files and more",expanded:addMenu),node(6,1,"AXButton","Send"),node(7,1,"AXButton",plan ? "Plan":"unused")]
        var items:[Int]=[]
        if menu {
            nodes.append(node(8,0,"AXMenu","model menu"))
            let title=chinese ? "\(label) \(effort)，第 \(efforts.firstIndex(of:effort)!+1) 项，共 \(efforts.count) 项。" : "\(label) \(effort), \(efforts.firstIndex(of:effort)!+1) of \(efforts.count)"
            nodes.append(node(9,8,"AXMenuItem",chinese ? "强度":"Power",strings:[title]+(contradictoryPower ? ["6.1-sol low, 1 of 4"]:[])))
            nodes.append(node(10,8,"AXMenuItem","Speed \(speed.rawValue)"))
            if hideModelRows && !modelSubmenu {
                nodes.append(node(19,8,"AXMenuItem","Select model"))
                nodes.append(node(12,8,"AXStaticText",""));items += [9,10,11]
            } else {
                nodes.append(node(11,8,"AXRadioButton","6.1-sol",selected:model == "gpt-6.1-sol"))
                nodes.append(node(12,8,"AXRadioButton","6-luna",selected:model == "gpt-6-luna"));items += [9,10,11,12]
            }
            if speedMenu {
                nodes.append(node(13,8,"AXMenu","speed menu"))
                for (i,value) in ["standard","fast","ultrafast"].enumerated() {
                    nodes.append(node(14+i,13,"AXRadioButton",value,selected:speed.rawValue == value));items.append(14+i)
                }
            }
            if slider {
                nodes.append(AXNode(element:elements[18],parent:8,role:"AXSlider",name:"Power range",minimum:0,maximum:Double(efforts.count-1),valueSettable:true))
            }
            nodes.append(node(22,10,"AXStaticText",speed.rawValue))
        } else if addMenu {
            nodes.append(node(8,0,planList ? "AXList":"AXMenu","add menu"))
            nodes.append(node(21,8,planList ? "AXRow":"AXMenuItem",missingPlan ? "Unrelated":planList ? "":"Plan"))
            if planList { nodes.append(node(20,9,"AXStaticText",chinese ? "计划模式":"Plan mode")) }
            else { items.append(9) }
        }
        let live=documentURL.map {CurrentRoute.resolve(documents:[$0],selectedLinks:selectedLinks,homeComposer:homeMarker,composerAvailable:true)}
        return MacUISnapshot(app:NSRunningApplication.current,root:elements[0],window:elements[0],nodes:nodes,composer:2,container:1,thread:live?.threadID ?? (documentURL == nil && changed ? "01000000-0000-0000-0000-000000000001":nil),draft:live?.draft ?? !changed,route:live?.key ?? (changed ? "thread:changed":"draft"),selectionKnown:live?.known ?? true,nativeFallback:false,selectedSidebar:nil,controls:plan ? [3,5,6,7]:[3,5,6],menuItems:items,blocked:blocked,modelLabels:Self.models.flatMap(NativeComposerSelection.labels),clientBinding:live?.pendingBinding)
    }
    func run(_ controller:MacUIController,_ operation:String,_ values:[String:Any]=[:]) async throws -> [String:Any] {
        let before=try await controller.execute("get_keypad_ui_state",arguments:[:],models:Self.models)
        let token=try XCTUnwrap(before["targetToken"] as? String)
        return try await controller.execute(operation,arguments:values.merging(["target_token":token,"expected_settings":before["settings"] ?? [:]]) { value,_ in value },models:Self.models)
    }
    func record(_ scenario:String,desktopBackend:Bool=false) {
        let result:[String:Any]=["scenario":scenario,"events":events,"model":model,"effort":effort,"speed":speed.rawValue,"plan":plan,"menuOpen":menu||addMenu,"desktopBackend":desktopBackend]
        ReplayTrace.emit("NATIVE-TRACE",result)
    }
}

private actor NativeCoreBoundary:DesktopCoreAccess {
    var models=NativeTraceRig.models
    var failModels=false
    var reads=0
    var onModels:(@Sendable ()->Void)?
    var binding:[String:Any]=["resolved":false]
    var rosterScope=String(repeating:"a",count:64),rosterContext="native-replay"
    var bindingReads=0
    var onBinding:(@Sendable ()->Void)?
    var onNewDraft:(@Sendable ()->Void)?
    var visibleContexts:[String]=[]
    var stateReads:[String]=[]
    func navigateOnNewDraft(_ callback:@escaping @Sendable ()->Void) {onNewDraft=callback}
    func setVisible(_ ids:[String]) {visibleContexts=ids}
    private var pauseBinding=false
    private var pausedBinding:CheckedContinuation<Void,Never>?
    var bindingIsPaused:Bool {pausedBinding != nil}
    func pauseNextBinding() {pauseBinding=true}
    func releaseBinding() {let value=pausedBinding;pausedBinding=nil;value?.resume()}
    func onNextBinding(_ callback:@escaping @Sendable ()->Void) {onBinding=callback}
    func replaceBinding(_ value:[String:Any]) {binding=value}
    func setScope(_ value:String) {rosterScope=value}
    func bind(client:String,thread:String) {binding=["resolved":true,"clientThreadId":client,"threadId":thread,"thread":["id":thread,"title":"Bound chat"],"rosterScope":rosterScope,"contextID":rosterContext]}
    private var pauseNext=false
    private var paused:CheckedContinuation<Void,Never>?
    var isPaused:Bool {paused != nil}
    func configure(models:[[String:Any]]?=nil,fail:Bool=false) {if let models {self.models=models};failModels=fail}
    func onNextModels(_ callback:@escaping @Sendable ()->Void) {onModels=callback}
    func pauseNextModels() {pauseNext=true}
    func releaseModels() {let value=paused;paused=nil;value?.resume()}
    func close() async {}
    func execute(_ operation:String,arguments:[String:Any]) async throws -> [String:Any] {
        switch operation {
        case "new_keypad_thread":
            let callback=onNewDraft;onNewDraft=nil;callback?()
            return ["launch_requested":true,"navigation_verified":false]
        case "get_keypad_state":
            let id=arguments["thread_id"] as? String ?? "";stateReads.append(id)
            return ["threadId":id,"model":"gpt-6.1-sol","effort":"medium","serviceTier":NSNull(),"collaborationMode":["mode":"default"],"canSubmit":true]
        case "get_keypad_client_thread":
            bindingReads += 1
            if pauseBinding {pauseBinding=false;await withCheckedContinuation {pausedBinding=$0}}
            let callback=onBinding;onBinding=nil;callback?();return binding
        case "get_keypad_models":
            reads += 1
            if pauseNext {pauseNext=false;await withCheckedContinuation {paused=$0}}
            let callback=onModels;onModels=nil;callback?()
            if failModels {throw CodexClientError.unavailable("Fixture catalog unavailable")}
            return ["data":models]
        case "list_keypad_threads":return ["threads":[],"contextID":rosterContext,"rosterScope":rosterScope]
        case "get_keypad_layout":return ["encoderMode":"reasoning","slots":[:]]
        case "get_keypad_capabilities","get_keypad_usage":return [:]
        case "get_keypad_activity":return ["watching":true,"streamConnected":true,"contextValid":true,"contextID":rosterContext,"visibilityKnown":true,"visibleContexts":visibleContexts]
        default:throw CodexClientError.unsupported("Unexpected core fixture operation: "+operation)
        }
    }
}

@MainActor private final class NativePanelBoundary:DesktopControlling {
    let controller:MacUIController
    let core=NativeCoreBoundary()
    let backend:DesktopBackend
    var writes:[(String,[String:Any])]=[]
    init(_ rig:NativeTraceRig) {
        controller=MacUIController(io:rig.access)
        backend=DesktopBackend(core:core,ui:controller)
    }
    func close() async {await backend.close()}
    func execute(_ operation:String,arguments:[String:Any]) async throws -> [String:Any] {
        if !operation.hasPrefix("get_"),!operation.hasPrefix("list_") {writes.append((operation,arguments))}
        return try await backend.execute(operation,arguments:arguments)
    }
}

@MainActor final class NativeTaskCommandReplayTests:XCTestCase {
    func testCustomTaskCommandsUseNativeDraftQueueAndReadback() async throws {
        let rig=NativeTraceRig(),suite="NativeTaskCommandReplay."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!,client=NativePanelBoundary(rig),settings=Settings(defaults:defaults)
        var profile=settings.layout;profile.agentSource="custom"
        profile.taskCommands=[String(repeating:"a",count:64):["AG00":"composer.toggleFastMode","AG01":"composer.togglePlanMode","AG13":"composer.increaseReasoningEffort"]]
        settings.setLayout(profile)
        let panel=MicroModel(settings:settings,client:client)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground();XCTAssertTrue(panel.isDraft)
        for index in [0,1,13] {try XCTUnwrap(panel.prepareTask(index),"slot \(index)")()}
        for _ in 0..<500 where panel.controlling {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(panel.controlError);XCTAssertTrue(panel.fast);XCTAssertEqual(panel.collaborationMode,"plan");XCTAssertEqual(panel.currentEffort,"high")
        XCTAssertEqual(client.writes.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning"])
        XCTAssertTrue(client.writes.allSatisfy {$0.1["thread_id"] == nil});XCTAssertFalse(rig.menu || rig.addMenu)
        ReplayTrace.emit("TASK-COMMAND-TRACE",["scenario":"U14 custom keys to native draft queue and readback","desktopBackend":true,"events":rig.events,"writes":client.writes.map(\.0),"fast":panel.fast,"mode":panel.collaborationMode ?? "unknown","effort":panel.currentEffort])
    }
}

final class NativeLampFocusTests:XCTestCase {
    func testPhysicalFocusDoesNotReuseSubmissionFocusMemory() async throws {
        let rig=NativeTraceRig(),microPID:Int32=900000
        let controller=MacUIController(io:rig.access,controllerPID:microPID)
        let target=NSRunningApplication.current.processIdentifier
        let states:[(Int32?,Bool,Bool)]=[(target,true,true),(microPID,false,true),(900001,false,false),(microPID,false,false),(nil,false,false),(target,true,true)]
        for (pid,physical,remembered) in states {
            rig.frontPID=pid
            let state=try await controller.execute("get_keypad_ui_state",arguments:[:],models:NativeTraceRig.models)
            XCTAssertEqual(state["appFocused"] as? Bool,physical)
            XCTAssertEqual(state["foreground"] as? Bool,remembered)
        }
        XCTAssertTrue(rig.events.isEmpty)
        ReplayTrace.emit("LAMP-TRACE",["scenario":"L09 native physical focus versus submission memory","focusTransitions":states.count,"events":rig.events])
    }
}

final class NativeComposerReplayTests:XCTestCase {
    func testDescendantHelpAndPowerAnnouncementsResolveSelection() {
        let model=NativeTraceRig.models
        XCTAssertEqual(NativeComposerSelection.parse(["Select model","6.1-sol","Extra high"],models:model)?.effort,"xhigh")
        XCTAssertEqual(NativeComposerSelection.power(["Power","6.1-sol high, 3 of 4"],models:model)?.position,3)
        XCTAssertNil(NativeComposerSelection.parse(["Select model"],models:model))
        XCTAssertNil(NativeComposerSelection.parse(["6.1-sol high 4 of 4"],models:model))
        XCTAssertNil(NativeComposerSelection.parse(["6.1-sol high","6-luna low"],models:model))
        XCTAssertNil(NativeComposerSelection.parse(["6.1-sol high 99999999999999999999999999 of 4"],models:model))
    }
    func testPlanWithoutCustomShortcutOrKnownModelUsesNativeMenuRoundTrip() async throws {
        let rig=NativeTraceRig()
        let actual=MacUIController(io:rig.access)
        _ = try await rig.run(actual,"toggle_keypad_draft_plan")
        XCTAssertTrue(rig.plan)
        _ = try await rig.run(actual,"toggle_keypad_draft_plan")
        XCTAssertFalse(rig.plan);XCTAssertEqual(rig.events,["press:add","press:plan","press:plan"])
        rig.record("N01 Plan native menu round trip")
    }
    func testConfiguredPlanShortcutFocusesTheComposerFirst() async throws {
        let rig=NativeTraceRig();rig.commands["composer.togglePlanMode"] = .init(key:96,flags:[])
        _ = try await rig.run(MacUIController(io:rig.access),"toggle_keypad_draft_plan")
        XCTAssertEqual(rig.events,["focus:editor","key:96@editor"]);XCTAssertTrue(rig.plan)
        rig.record("N02 Plan shortcut focus")
    }
    func testPlanModeInTheNewComposerSuggestionListPreservesText() async throws {
        for chinese in [false,true] {
            let rig=NativeTraceRig();rig.planList=true;rig.chinese=chinese
            let result=try await rig.run(MacUIController(io:rig.access),"toggle_keypad_draft_plan")
            XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertTrue(rig.plan);XCTAssertFalse(rig.addMenu)
            XCTAssertEqual(rig.events,["press:add","press:plan"])
            XCTAssertEqual(rig.snapshot().editor?.text,"fixture prompt")
            rig.record("N19 Plan mode suggestion list " + (chinese ? "zh":"en"))
        }
    }
    func testFastMenuCyclesThreeDistinctSpeedsWithoutConfiguredShortcut() async throws {
        let rig=NativeTraceRig()
        let controller=MacUIController(io:rig.access)
        for expected in [NativeComposerSelection.Speed.fast,.ultrafast,.standard] {
            let result=try await rig.run(controller,"set_keypad_draft_fast",["toggle":true])
            XCTAssertEqual(rig.speed,expected);XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertFalse(rig.menu)
        }
        XCTAssertEqual(rig.events.filter{$0.hasPrefix("press:") && ["press:standard","press:fast","press:ultrafast"].contains($0)},["press:fast","press:ultrafast","press:standard"])
        rig.record("N03 Fast native speed cycle")
    }
    func testFastToUltrafastShortcutIsAConfirmedChange() async throws {
        let rig=NativeTraceRig();rig.speed = .fast;rig.commands["composer.toggleFastMode"] = .init(key:97,flags:[])
        let result=try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_fast",["toggle":true])
        let settings=(result["state"] as? [String:Any])?["settings"] as? [String:Any]
        XCTAssertEqual(settings?["nativeSpeed"] as? String,"ultrafast");XCTAssertFalse(rig.menu)
        rig.record("N04 Fast shortcut distinguishes Ultrafast")
    }
    func testExplicitFastOffTraversesUltrafastWithEachStepReadBack() async throws {
        let rig=NativeTraceRig();rig.speed = .fast;rig.commands["composer.toggleFastMode"] = .init(key:97,flags:[])
        _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_fast",["enabled":false])
        XCTAssertEqual(rig.speed,.standard);XCTAssertFalse(rig.menu)
        XCTAssertEqual(rig.events.filter{$0.hasPrefix("key:97")}.count,2)
        rig.record("N17 explicit Fast off through Ultrafast")
    }
    func testSpeedChoiceClosingTheWholeMenuReopensToReadBack() async throws {
        let rig=NativeTraceRig();rig.closeOnSpeed=true
        _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_fast",["toggle":true])
        XCTAssertEqual(rig.speed,.fast);XCTAssertFalse(rig.menu)
        XCTAssertEqual(rig.events.filter{$0 == "press:picker"}.count,2)
        rig.record("N18 speed closes picker and readback reopens")
    }
    func testMindReadsHiddenInitialEffortAndUsesFocusedPowerArrows() async throws {
        let rig=NativeTraceRig()
        let actual=MacUIController(io:rig.access)
        _ = try await rig.run(actual,"set_keypad_draft_reasoning",["direction":1])
        XCTAssertEqual(rig.effort,"high")
        _ = try await rig.run(actual,"set_keypad_draft_reasoning",["direction":-1])
        XCTAssertEqual(rig.effort,"medium");XCTAssertFalse(rig.menu)
        XCTAssertEqual(rig.events.filter{$0.hasPrefix("focus:")},["focus:power","focus:power"])
        rig.record("N05 MIND Power keyboard round trip")
    }
    func testMindUsesValidatedSliderRangeAndStopsAtBoundary() async throws {
        let rig=NativeTraceRig();rig.slider=true;rig.effort="high"
        let controller=MacUIController(io:rig.access)
        _ = try await rig.run(controller,"set_keypad_draft_reasoning",["direction":1])
        _ = try await rig.run(controller,"set_keypad_draft_reasoning",["direction":1])
        XCTAssertEqual(rig.effort,"xhigh");XCTAssertEqual(rig.events.filter{$0.hasPrefix("range:")},["range:3"])
        rig.record("N06 MIND range and upper boundary")
    }
    func testQuickModelResolvesActualUnknownTriggerBeforeChoosingAB() async throws {
        let rig=NativeTraceRig()
        _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_model",["quick_models":[["model":"gpt-6.1-sol","effort":"medium"],["model":"gpt-6-luna","effort":"high"]]])
        XCTAssertEqual(rig.model,"gpt-6-luna");XCTAssertEqual(rig.effort,"high");XCTAssertFalse(rig.menu)
        XCTAssertTrue(rig.events.contains("press:model-b"));XCTAssertFalse(rig.events.contains("press:model-a"))
        rig.record("N07 A/B resolves actual menu state")
    }
    func testModelSubmenuAndClosedGenericTriggerReopenForRealReadback() async throws {
        let rig=NativeTraceRig();rig.hideModelRows=true;rig.closeOnModel=true
        _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_model",["model":"gpt-6-luna","effort":"high"])
        XCTAssertEqual(rig.model,"gpt-6-luna");XCTAssertEqual(rig.effort,"high");XCTAssertFalse(rig.menu)
        XCTAssertEqual(rig.events.filter{$0.hasPrefix("press:")},["press:picker","press:select-model","press:model-b","press:picker"])
        rig.record("N16 model submenu and closed-trigger readback")
    }
    func testUnsupportedEffortDoesNotPartiallyChangeModel() async {
        let rig=NativeTraceRig()
        do { _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_model",["model":"gpt-6-luna","effort":"xhigh"]);XCTFail("Must reject") } catch {}
        XCTAssertEqual(rig.model,"gpt-6.1-sol");XCTAssertFalse(rig.events.contains("press:model-b"));XCTAssertFalse(rig.menu)
        rig.record("N08 invalid effort before model mutation")
    }
    func testConflictingPowerNeverFallsBackToStaleTrigger() async {
        let rig=NativeTraceRig();rig.generic=false;rig.contradictoryPower=true
        do { _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_reasoning",["direction":1]);XCTFail("Must reject") } catch {}
        XCTAssertEqual(rig.effort,"medium");XCTAssertFalse(rig.events.contains("focus:power"));XCTAssertFalse(rig.menu)
        rig.record("N09 conflicting Power rejects")
    }
    func testChinesePowerAnnouncementDrivesTheSameNativeController() async throws {
        let rig=NativeTraceRig();rig.chinese=true
        _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_reasoning",["direction":1])
        XCTAssertEqual(rig.effort,"high");XCTAssertFalse(rig.menu)
        rig.record("N12 Chinese Power labels and position")
    }
    func testUnavailablePlanClosesOnlyTheMenuItOpened() async {
        let rig=NativeTraceRig();rig.missingPlan=true
        do { _ = try await rig.run(MacUIController(io:rig.access),"toggle_keypad_draft_plan");XCTFail("Must reject") } catch {}
        XCTAssertFalse(rig.plan);XCTAssertFalse(rig.addMenu);XCTAssertEqual(rig.events,["press:add","key:53@none"])
        rig.record("N13 missing Plan menu cleanup")
    }
    func testTargetSwitchWhileFocusingPreventsShortcutAndCleanupToAnotherTarget() async {
        let rig=NativeTraceRig();rig.onFocus={rig.changed=true}
        do { _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_reasoning",["direction":1]);XCTFail("Must reject") } catch {}
        XCTAssertFalse(rig.events.contains(where:{$0.hasPrefix("key:")}));XCTAssertEqual(rig.effort,"medium")
        rig.record("N10 target switch before native key")
    }
    func testModelPermissionDialogIsNeverAutomaticallyConfirmed() async {
        let rig=NativeTraceRig();rig.onModel={rig.blocked=true}
        do { _ = try await rig.run(MacUIController(io:rig.access),"set_keypad_draft_model",["model":"gpt-6-luna","effort":"high"]);XCTFail("Must remain unknown") } catch {}
        XCTAssertEqual(rig.events,["press:picker","press:model-b"])
        rig.record("N11 pending decision is not accepted")
    }
    @MainActor func testPanelToNativeControllerMixedDraftActionsAndQuickModel() async throws {
        let rig=NativeTraceRig(),suite="NativePanelReplay."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!,client=NativePanelBoundary(rig)
        let panel=MicroModel(settings:Settings(defaults:defaults),client:client)
        defer { panel.stop();defaults.removePersistentDomain(forName:suite) }
        await panel.refresh();await panel.refreshForeground()
        XCTAssertTrue(panel.isDraft);XCTAssertEqual(panel.currentModel,"")
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]),command)()
        }
        for _ in 0..<500 where panel.controlling { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertNil(panel.controlError);XCTAssertTrue(panel.fast);XCTAssertEqual(panel.collaborationMode,"plan");XCTAssertEqual(panel.currentEffort,"high")
        XCTAssertEqual(client.writes.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning"])
        XCTAssertTrue(client.writes.allSatisfy { $0.1["thread_id"] == nil })
        var profile=DialProfile();profile.a = .init(model:"gpt-6.1-sol",effort:"medium");profile.b = .init(model:"gpt-6-luna",effort:"high")
        panel.toggleQuickModel(profile,target:try XCTUnwrap(panel.controlTarget))
        for _ in 0..<500 where panel.controlling { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertNil(panel.controlError);XCTAssertEqual(panel.currentModel,"gpt-6-luna");XCTAssertEqual(panel.currentEffort,"high")
        await panel.refreshForeground()
        XCTAssertEqual(panel.currentModel,"gpt-6-luna");XCTAssertEqual(panel.currentEffort,"high")
        rig.record("N14 panel queue to native menu to readback",desktopBackend:true)
    }
    func testExternalInvisibleSelectionChangeIsRecheckedBeforeWriting() async throws {
        let rig=NativeTraceRig()
        let actual=MacUIController(io:rig.access)
        _ = try await rig.run(actual,"set_keypad_draft_reasoning",["direction":1])
        rig.model="gpt-6-luna";rig.effort="low";rig.events=[]
        do { _ = try await rig.run(actual,"set_keypad_draft_reasoning",["direction":1]);XCTFail("Must reject stale cached selection") } catch {}
        XCTAssertEqual(rig.effort,"low");XCTAssertFalse(rig.events.contains("focus:power"))
        rig.record("N15 stale displayed selection rechecked")
    }
}

@MainActor final class NativeClientRouteReplayTests:XCTestCase {
    let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    var client:String {"client-new-thread:"+a}
    func settle(_ panel:MicroModel) async throws {
        for _ in 0..<500 where panel.controlling {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(panel.controlling)
    }
    func record(_ scenario:String,_ values:[String:Any]) {ReplayTrace.emit("CLIENT-ROUTE-TRACE",values.merging(["scenario":scenario]) {a,_ in a})}
    func testClientComposerUsesRealSettingsQueueModelAndNativeReadback() async throws {
        var paths:[String]=[],allWrites:[String]=[]
        for prefix in ["/local/","/hotkey-window/thread/"] {
            let rig=NativeTraceRig();rig.documentURL="app://-"+prefix+client
            let suite="NativeClientRoute."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!,boundary=NativePanelBoundary(rig)
            let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
            defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
            await panel.refresh();await panel.refreshForeground()
            XCTAssertTrue(panel.isNativeComposer);XCTAssertFalse(panel.isDraft);XCTAssertNil(panel.selectedID)
            for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
                try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]))()
            }
            try await settle(panel)
            XCTAssertNil(panel.controlError);XCTAssertTrue(panel.fast);XCTAssertEqual(panel.collaborationMode,"plan");XCTAssertEqual(panel.currentEffort,"high")
            var profile=DialProfile();profile.a = .init(model:"gpt-6.1-sol",effort:"medium");profile.b = .init(model:"gpt-6-luna",effort:"high")
            panel.toggleQuickModel(profile,target:try XCTUnwrap(panel.controlTarget));try await settle(panel)
            XCTAssertNil(panel.controlError);XCTAssertEqual(panel.currentModel,"gpt-6-luna");XCTAssertEqual(panel.currentEffort,"high")
            XCTAssertEqual(boundary.writes.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning","set_keypad_draft_model"])
            XCTAssertTrue(boundary.writes.allSatisfy {$0.1["thread_id"] == nil && $0.1["native_composer"] as? Bool == true})
            XCTAssertFalse(rig.menu);paths.append(prefix);allWrites += boundary.writes.map(\.0)
        }
        record("W08 client settings and model readback",["paths":paths,"writes":allWrites,"serverIDsSent":0,"desktopBackend":true])
    }
    func testBoundClientIDTraversesDesktopBackendWithoutChangingNativeDispatch() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+client
        let suite="NativeBoundClient."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!,boundary=NativePanelBoundary(rig)
        let server="01000000-0000-0000-0000-000000000003"
        await boundary.core.bind(client:client,thread:server)
        let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground()
        XCTAssertEqual(panel.currentThreadID,server);XCTAssertNil(panel.selectedID)
        try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.togglePlanMode"]))();try await settle(panel)
        XCTAssertEqual(boundary.writes.map(\.0),["toggle_keypad_draft_plan"])
        XCTAssertTrue(boundary.writes.allSatisfy {$0.1["thread_id"] == nil && $0.1["native_composer"] as? Bool == true})
        XCTAssertTrue(rig.plan);XCTAssertFalse(panel.canFork)
        ReplayTrace.emit("CLIENT-BINDING-TRACE",["scenario":"Y13 bound ID through production desktop dispatch","desktopBackend":true,"currentID":server,"nativePlan":rig.plan,"serverIDsSent":0])
    }
    func testClientSwitchWithIdenticalAXNodesInvalidatesBeforeKeyboardWrite() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+client
        rig.onFocus={rig.documentURL="app://-/local/client-new-thread:"+self.b}
        let controller=MacUIController(io:rig.access)
        do {_ = try await rig.run(controller,"set_keypad_draft_reasoning",["direction":1,"native_composer":true]);XCTFail("Changed client must fail")} catch {}
        XCTAssertEqual(rig.effort,"medium");XCTAssertFalse(rig.events.contains {$0.hasPrefix("key:")})
        XCTAssertEqual(rig.snapshot().clientThreadID,"client-new-thread:"+b)
        record("W09 changed client before input",["events":rig.events,"effort":rig.effort,"sameAXElements":true])
    }
    func testServerRouteRetiresClientTokenAndOnlyThenPublishesUUID() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+client
        let controller=MacUIController(io:rig.access),before=try await controller.execute("get_keypad_ui_state",arguments:[:],models:NativeTraceRig.models)
        XCTAssertEqual(before["clientThreadId"] as? String,client);XCTAssertNil(before["threadId"] as? String)
        rig.documentURL="app://-/local/"+b
        do {_ = try await controller.execute("set_keypad_draft_fast",arguments:["target_token":try XCTUnwrap(before["targetToken"]),"native_composer":true,"enabled":true],models:NativeTraceRig.models);XCTFail("Old token must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        let after=try await controller.execute("get_keypad_ui_state",arguments:[:],models:NativeTraceRig.models)
        XCTAssertEqual(after["threadId"] as? String,b);XCTAssertNil(after["clientThreadId"] as? String)
        XCTAssertEqual(after["nativeComposer"] as? Bool,false);XCTAssertNotEqual(before["targetToken"] as? String,after["targetToken"] as? String)
        record("W10 client to server route",["clientThreadId":client,"serverUUID":b,"oldTokenDispatched":false])
    }
    func testClientIdentityNeverAuthorizesSubmitStopApprovalOrFork() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+client
        let suite="NativeClientGates."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!,boundary=NativePanelBoundary(rig)
        let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground()
        let commands=["composer.submit","turn.cancel","approval.approve","forkThread","composer.dictation","composer.sketch"]
        for command in commands {XCTAssertNil(panel.prepareBinding(["type":"command","commandId":command]),command)}
        let state=try await boundary.controller.execute("get_keypad_ui_state",arguments:[:],models:NativeTraceRig.models)
        XCTAssertEqual(state["canSubmit"] as? Bool,false)
        for operation in ["submit_keypad_composer","navigate_keypad_ui","insert_keypad_skill"] {
            do {_ = try await boundary.controller.execute(operation,arguments:["target_token":try XCTUnwrap(state["targetToken"])],models:NativeTraceRig.models);XCTFail(operation)} catch {}
        }
        XCTAssertTrue(rig.events.isEmpty);XCTAssertTrue(boundary.writes.isEmpty)
        record("W11 client business action gates",["commands":commands,"dispatches":0])
    }
    func testActualRemoteRouteProjectionVetoesStaleLocalIPC() async throws {
        let rig=PanelRig(),native=NativeTraceRig(),suite="NativeHostVeto."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        let panel=MicroModel(settings:Settings(defaults:defaults),client:rig)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground();await panel.refreshActivity()
        XCTAssertEqual(panel.selectedID,a)
        native.documentURL="app://-/local/\(a)?hostId=remote-workstation"
        rig.ui=try await MacUIController(io:native.access).execute("get_keypad_ui_state",arguments:[:],models:NativeTraceRig.models)
        await panel.refreshForeground();await panel.refreshActivity()
        XCTAssertNil(panel.selectedID);XCTAssertNil(panel.controlTarget);XCTAssertFalse(panel.isNativeComposer)
        XCTAssertNil(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))
        XCTAssertTrue(rig.mutations.isEmpty);XCTAssertTrue(native.events.isEmpty)
        record("W12 remote route vetoes local IPC",["staleVisibleID":a,"dispatches":0])
    }
    func testKnownClientRouteRequiresMatchingProjectedClientIdentity() async throws {
        let rig=PanelRig(),suite="ClientProjection."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        let panel=MicroModel(settings:Settings(defaults:defaults),client:rig)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh()
        rig.ui=["available":true,"selectionKnown":true,"nativeComposer":true,"targetToken":"client-token","routeKey":"client:"+client,"settings":rig.thread,"draftFastAvailable":true]
        for identity in [NSNull() as Any,"client-new-thread:"+b,client] {
            rig.ui["clientThreadId"]=identity;await panel.refreshForeground()
            XCTAssertEqual(panel.isNativeComposer,identity as? String == client)
            XCTAssertNil(panel.selectedID)
        }
        XCTAssertTrue(rig.mutations.isEmpty)
        record("W13 projected client identity match",["cases":3,"dispatches":0])
    }
}

@MainActor final class DesktopBackendReplayTests:XCTestCase {
    let client="client-new-thread:01000000-0000-0000-0000-000000000001"
    private func setup() async throws -> (NativeTraceRig,NativePanelBoundary,[String:Any]) {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+client
        let boundary=NativePanelBoundary(rig)
        _ = try await boundary.execute("get_keypad_models",arguments:[:])
        let state=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        return (rig,boundary,["target_token":try XCTUnwrap(state["targetToken"]),"native_composer":true])
    }
    func testRemovedModelIsRejectedBeforeAnyNativeInput() async throws {
        let (rig,boundary,args)=try await setup()
        await boundary.core.configure(models:[NativeTraceRig.models[0]])
        do {_ = try await boundary.execute("set_keypad_draft_model",arguments:args.merging(["model":"gpt-6-luna","effort":"high"]) {_,new in new});XCTFail("Removed model must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty);XCTAssertEqual(rig.model,"gpt-6.1-sol")
        let reads=await boundary.core.reads;XCTAssertEqual(reads,2)
        ReplayTrace.emit("DESKTOP-BACKEND-TRACE",["scenario":"X02 removed model at dispatch","catalogReads":reads,"nativeEvents":rig.events])
    }
    func testFailedFreshCatalogDoesNotReuseCachedModelsOrRetry() async throws {
        let (rig,boundary,args)=try await setup()
        await boundary.core.configure(fail:true)
        do {_ = try await boundary.execute("set_keypad_draft_reasoning",arguments:args.merging(["direction":1]) {_,new in new});XCTFail("Failed catalog must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        let observed=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertNil((observed["settings"] as? [String:Any])?["model"])
        let reads=await boundary.core.reads;XCTAssertEqual(reads,2)
        ReplayTrace.emit("DESKTOP-BACKEND-TRACE",["scenario":"X03 failed catalog cache invalidation","catalogReads":reads,"nativeEvents":rig.events])
    }
    func testClientChangeDuringCatalogReadInvalidatesOldTokenBeforeInput() async throws {
        let (rig,boundary,args)=try await setup()
        await boundary.core.onNextModels {rig.documentURL="app://-/local/client-new-thread:01000000-0000-0000-0000-000000000002"}
        do {_ = try await boundary.execute("toggle_keypad_draft_plan",arguments:args);XCTFail("New client must reject old token")} catch {}
        XCTAssertFalse(rig.plan);XCTAssertTrue(rig.events.isEmpty)
        ReplayTrace.emit("DESKTOP-BACKEND-TRACE",["scenario":"X04 client changes during catalog read","nativeEvents":rig.events])
    }
    func testUnsupportedEffortIsRejectedBeforeSwitchingModel() async throws {
        let (rig,boundary,args)=try await setup()
        var changed=NativeTraceRig.models[1];changed["supportedReasoningEfforts"]=[["reasoningEffort":"low"]]
        await boundary.core.configure(models:[NativeTraceRig.models[0],changed])
        do {_ = try await boundary.execute("set_keypad_draft_model",arguments:args.merging(["model":"gpt-6-luna","effort":"high"]) {_,new in new});XCTFail("Effort validation must precede model input")} catch {}
        XCTAssertEqual(rig.model,"gpt-6.1-sol");XCTAssertTrue(rig.events.isEmpty)
        ReplayTrace.emit("DESKTOP-BACKEND-TRACE",["scenario":"X05 unsupported model and effort pair","model":rig.model,"nativeEvents":rig.events])
    }
    func testConcurrentNativeWritesCannotInterleaveWhileCatalogReadAwaits() async throws {
        let (rig,boundary,args)=try await setup()
        await boundary.core.pauseNextModels()
        let first=Task {try await boundary.execute("set_keypad_draft_fast",arguments:args.merging(["toggle":true]) {_,new in new})}
        for _ in 0..<500 {
            if await boundary.core.isPaused {break}
            try await Task.sleep(for:.milliseconds(5))
        }
        let paused=await boundary.core.isPaused;XCTAssertTrue(paused)
        do {_ = try await boundary.execute("toggle_keypad_draft_plan",arguments:args);XCTFail("Concurrent write must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        await boundary.core.releaseModels()
        let result=try await first.value
        XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(rig.speed,.fast);XCTAssertFalse(rig.plan)
        let reads=await boundary.core.reads;XCTAssertEqual(reads,2)
        ReplayTrace.emit("DESKTOP-BACKEND-TRACE",["scenario":"X06 concurrent native writes","catalogReads":reads,"plan":rig.plan,"speed":rig.speed.rawValue,"nativeEvents":rig.events])
    }
}

@MainActor final class DraftRouteReplayTests:XCTestCase {
    func settle(_ panel:MicroModel) async throws {
        for _ in 0..<500 where panel.controlling {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(panel.controlling)
    }
    private func settings(_ path:String,home:Bool,scenario:String) async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-"+path;rig.homeMarker=home
        let suite="NativeDraftRoute."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!,boundary=NativePanelBoundary(rig)
        let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground()
        XCTAssertTrue(panel.isDraft);XCTAssertFalse(panel.isNativeComposer);XCTAssertNil(panel.currentThreadID)
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]))()
        }
        try await settle(panel)
        XCTAssertNil(panel.controlError);XCTAssertTrue(panel.fast);XCTAssertEqual(panel.collaborationMode,"plan");XCTAssertEqual(panel.currentEffort,"high")
        var profile=DialProfile();profile.a = .init(model:"gpt-6.1-sol",effort:"medium");profile.b = .init(model:"gpt-6-luna",effort:"high")
        panel.toggleQuickModel(profile,target:try XCTUnwrap(panel.controlTarget));try await settle(panel)
        XCTAssertNil(panel.controlError);XCTAssertEqual(panel.currentModel,"gpt-6-luna");XCTAssertEqual(panel.currentEffort,"high")
        XCTAssertEqual(boundary.writes.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning","set_keypad_draft_model"])
        XCTAssertTrue(boundary.writes.allSatisfy {$0.1["thread_id"] == nil && $0.1["native_composer"] as? Bool != true})
        ReplayTrace.emit("DRAFT-ROUTE-TRACE",["scenario":scenario,"path":path,"writes":boundary.writes.map(\.0),"desktopBackend":true,"sendCount":0])
    }
    func testHotkeyHomeRunsFastPlanMindAndModelThroughDesktopDispatch() async throws {
        try await settings("/hotkey-window",home:false,scenario:"Z07 hotkey home settings")
    }
    func testHotkeyNewThreadRunsFastPlanMindAndModelThroughDesktopDispatch() async throws {
        try await settings("/hotkey-window/new-thread",home:false,scenario:"Z08 hotkey new thread settings")
    }
    func testProjectDraftRunsFastPlanMindAndModelThroughDesktopDispatch() async throws {
        try await settings("/projects?projectId=02000000-0000-0000-0000-000000000001",home:true,scenario:"Z09 project draft settings")
    }
    func testChangingProjectWithReusedElementsRetiresCapturedSetting() async throws {
        let rig=NativeTraceRig();rig.homeMarker=true;rig.documentURL="app://-/projects?projectId=project-a"
        let boundary=NativePanelBoundary(rig);_ = try await boundary.execute("get_keypad_models",arguments:[:])
        let old=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(old["draft"] as? Bool,true)
        rig.documentURL="app://-/projects?projectId=project-b"
        let next=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertNotEqual(old["targetToken"] as? String,next["targetToken"] as? String)
        do {_ = try await boundary.execute("toggle_keypad_draft_plan",arguments:["target_token":try XCTUnwrap(old["targetToken"] as? String)]);XCTFail("Old project token must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        ReplayTrace.emit("DRAFT-ROUTE-TRACE",["scenario":"Z10 reused composer switches project","retired":true,"events":rig.events,"desktopBackend":true])
    }
    func testDraftBecomingClientRouteDuringCatalogReadRejectsOldCommand() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/hotkey-window/new-thread"
        let boundary=NativePanelBoundary(rig);_ = try await boundary.execute("get_keypad_models",arguments:[:])
        let old=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(old["draft"] as? Bool,true)
        await boundary.core.onNextModels {rig.documentURL="app://-/hotkey-window/thread/client-new-thread:01000000-0000-0000-0000-000000000001"}
        do {_ = try await boundary.execute("toggle_keypad_draft_plan",arguments:["target_token":try XCTUnwrap(old["targetToken"] as? String)]);XCTFail("Created client must retire draft")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        ReplayTrace.emit("DRAFT-ROUTE-TRACE",["scenario":"Z11 draft becomes client during lookup","events":rig.events,"desktopBackend":true])
    }
}

@MainActor final class ClientAliasReplayTests:XCTestCase {
    let client="client-new-thread:01000000-0000-0000-0000-000000000001"
    let server="01000000-0000-0000-0000-000000000002"
    private func setup(observeRoster:Bool=true) async throws -> (NativeTraceRig,NativePanelBoundary,[String:Any]) {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+client;rig.selectedLinks=["/local/"+server]
        let boundary=NativePanelBoundary(rig);await boundary.core.bind(client:client,thread:server)
        if observeRoster {_ = try await boundary.execute("list_keypad_threads",arguments:[:])}
        _ = try await boundary.execute("get_keypad_models",arguments:[:])
        let state=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        return (rig,boundary,state)
    }
    private func settle(_ panel:MicroModel) async throws {
        for _ in 0..<500 where panel.controlling {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(panel.controlling)
    }
    func record(_ id:String,_ values:[String:Any]=[:]) {ReplayTrace.emit("CLIENT-ALIAS-TRACE",values.merging(["scenario":id,"desktopBackend":true]) {a,_ in a})}
    func testRawNativeCandidateHasNoControlTokenAndCannotBeUsedDirectly() async throws {
        let (rig,boundary,_)=try await setup(observeRoster:false)
        let raw=try await boundary.controller.execute("get_keypad_ui_state",arguments:[:],models:NativeTraceRig.models)
        XCTAssertEqual(raw["available"] as? Bool,false);XCTAssertEqual(raw["nativeComposer"] as? Bool,false)
        XCTAssertTrue(raw["targetToken"] is NSNull);XCTAssertNotNil(raw["clientBindingCandidate"])
        let observation=try XCTUnwrap(raw["bindingObservationToken"] as? String)
        do {_ = try await boundary.controller.execute("toggle_keypad_draft_plan",arguments:["target_token":observation,"native_composer":true],models:NativeTraceRig.models);XCTFail("An observation is not a control token")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        record("AA06 raw candidate cannot dispatch",["events":rig.events])
    }
    func testBothAliasDirectionsRunSettingsAndExposeVerifiedUUIDThroughFullPanel() async throws {
        var writes:[String]=[]
        for documentIsClient in [true,false] {
            let rig=NativeTraceRig()
            rig.documentURL="app://-/local/"+(documentIsClient ? client:server)
            rig.selectedLinks=["/local/"+(documentIsClient ? server:client)]
            let boundary=NativePanelBoundary(rig);await boundary.core.bind(client:client,thread:server)
            let suite="NativeClientAlias."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
            let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
            defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
            await panel.refresh();await panel.refreshForeground()
            XCTAssertTrue(panel.isNativeComposer);XCTAssertFalse(panel.isDraft);XCTAssertNil(panel.selectedID)
            XCTAssertEqual(panel.currentThreadID,server);XCTAssertEqual(panel.foreground["clientBindingVerified"] as? Bool,true)
            for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
                try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]))()
            }
            try await settle(panel)
            XCTAssertNil(panel.controlError);XCTAssertTrue(panel.fast);XCTAssertEqual(panel.collaborationMode,"plan");XCTAssertEqual(panel.currentEffort,"high")
            var profile=DialProfile();profile.a = .init(model:"gpt-6.1-sol",effort:"medium");profile.b = .init(model:"gpt-6-luna",effort:"high")
            panel.toggleQuickModel(profile,target:try XCTUnwrap(panel.controlTarget));try await settle(panel)
            XCTAssertNil(panel.controlError);XCTAssertEqual(panel.currentModel,"gpt-6-luna");XCTAssertEqual(panel.currentEffort,"high")
            XCTAssertEqual(boundary.writes.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning","set_keypad_draft_model"])
            XCTAssertTrue(boundary.writes.allSatisfy {$0.1["thread_id"] == nil && $0.1["native_composer"] as? Bool == true})
            XCTAssertFalse(panel.canFork);writes += boundary.writes.map(\.0)
        }
        record("AA07 both alias directions through full panel",["writes":writes,"serverIDsSent":0,"currentID":server])
    }
    func testMissingRosterScopeCannotQueryOrConfirmBinding() async throws {
        let (rig,boundary,state)=try await setup(observeRoster:false)
        XCTAssertEqual(state["available"] as? Bool,false);XCTAssertTrue(state["targetToken"] is NSNull)
        let reads=await boundary.core.bindingReads;XCTAssertEqual(reads,0);XCTAssertTrue(rig.events.isEmpty)
        record("AA08 missing roster scope",["bindingReads":reads])
    }
    func testMismatchedCoreEnvelopesNeverConfirmPair() async throws {
        let (rig,boundary,_)=try await setup(),good=await boundary.core.binding
        let variants:[(String,Any)]=[("resolved",false),("rosterScope",String(repeating:"b",count:64)),("contextID","old-session"),
            ("clientThreadId","client-new-thread:"+server),("threadId","01000000-0000-0000-0000-000000000003"),("thread",["id":"01000000-0000-0000-0000-000000000003"])]
        for (key,value) in variants {
            var bad=good;bad[key]=value;await boundary.core.replaceBinding(bad)
            let state=try await boundary.execute("get_keypad_ui_state",arguments:[:])
            XCTAssertEqual(state["available"] as? Bool,false);XCTAssertTrue(state["targetToken"] is NSNull)
        }
        XCTAssertTrue(rig.events.isEmpty)
        record("AA09 mismatched binding envelopes",["rejected":variants.count,"events":rig.events])
    }
    func testBindingRemovalAfterObservationRejectsOldNativeWrite() async throws {
        let (rig,boundary,state)=try await setup()
        let token=try XCTUnwrap(state["targetToken"] as? String)
        await boundary.core.replaceBinding(["resolved":false])
        do {_ = try await boundary.execute("toggle_keypad_draft_plan",arguments:["target_token":token,"native_composer":true]);XCTFail("Removed binding must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        record("AA10 binding removed before write",["events":rig.events])
    }
    func testChangedAccountScopeRetiresTokenEvenWithSamePairAndElements() async throws {
        let (rig,boundary,first)=try await setup()
        let old=try XCTUnwrap(first["targetToken"] as? String)
        await boundary.core.setScope(String(repeating:"b",count:64));await boundary.core.bind(client:client,thread:server)
        _ = try await boundary.execute("list_keypad_threads",arguments:[:])
        let next=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(next["clientBindingVerified"] as? Bool,true);XCTAssertNotEqual(next["targetToken"] as? String,old)
        do {_ = try await boundary.execute("toggle_keypad_draft_plan",arguments:["target_token":old,"native_composer":true]);XCTFail("Old account token must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        record("AA11 account scope change retires old token",["events":rig.events])
    }
    func testWindowChangesDuringBindingReadCannotPublishConfirmation() async throws {
        let (rig,boundary,_)=try await setup()
        await boundary.core.onNextBinding {rig.documentURL="app://-/settings";rig.selectedLinks=[]}
        let state=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(state["available"] as? Bool,false);XCTAssertTrue(state["targetToken"] is NSNull)
        let current=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(current["routeKey"] as? String,"page:/settings");XCTAssertNil(current["clientBindingVerified"])
        XCTAssertTrue(rig.events.isEmpty)
        record("AA12 window changes during binding read",["events":rig.events])
    }
    func testAliasChangeAfterFocusRejectsKeyboardAndCleanupToDifferentTarget() async throws {
        let (rig,boundary,state)=try await setup()
        rig.onFocus={rig.selectedLinks=["/local/01000000-0000-0000-0000-000000000003"]}
        do {_ = try await boundary.execute("set_keypad_draft_reasoning",arguments:["target_token":try XCTUnwrap(state["targetToken"] as? String),"native_composer":true,"effort":"high"]);XCTFail("Changed pair must fail before keyboard")} catch {}
        XCTAssertFalse(rig.events.contains {$0.hasPrefix("key:") || $0.hasPrefix("range:")});XCTAssertEqual(rig.effort,"medium")
        record("AA13 alias changes at focus boundary",["events":rig.events,"effort":rig.effort])
    }
    func testAliasDirectionChangeRetiresOldToken() async throws {
        let (rig,boundary,first)=try await setup()
        rig.documentURL="app://-/local/"+server;rig.selectedLinks=["/local/"+client]
        let second=try await boundary.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(second["nativeComposer"] as? Bool,true);XCTAssertNotEqual(first["targetToken"] as? String,second["targetToken"] as? String)
        do {_ = try await boundary.execute("toggle_keypad_draft_plan",arguments:["target_token":try XCTUnwrap(first["targetToken"] as? String),"native_composer":true]);XCTFail("Old direction must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
        record("AA14 document selection direction changes",["events":rig.events])
    }
    func testVerifiedAliasStillCannotAuthorizeNativeBusinessOperations() async throws {
        let (rig,boundary,_)=try await setup()
        for (operation,extra) in [("submit_keypad_composer",[:]),("navigate_keypad_ui",["action":"sidebar"]),("insert_keypad_preset_text",["preset":"YOLO"]),("toggle_keypad_dictation",[:])] {
            let state=try await boundary.execute("get_keypad_ui_state",arguments:[:])
            var arguments:[String:Any]=extra;arguments["target_token"]=try XCTUnwrap(state["targetToken"] as? String)
            do {_ = try await boundary.execute(operation,arguments:arguments);XCTFail("Settings-only alias must not authorize "+operation)} catch {}
        }
        XCTAssertTrue(rig.events.isEmpty)
        record("AA15 alias remains settings-only",["events":rig.events,"rejected":4])
    }
    private func waitForBinding(_ boundary:NativePanelBoundary) async throws {
        for _ in 0..<100 {
            if await boundary.core.bindingIsPaused {return}
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Expected the binding fixture to be paused")
    }
    func testRosterRefreshDuringBindingLookupInvalidatesPendingReceipt() async throws {
        let (rig,boundary,_)=try await setup()
        await boundary.core.pauseNextBinding()
        let pending=Task {try await boundary.execute("get_keypad_ui_state",arguments:[:])}
        try await waitForBinding(boundary)
        _ = try await boundary.execute("list_keypad_threads",arguments:[:])
        await boundary.core.releaseBinding()
        let stale=try await pending.value
        XCTAssertEqual(stale["available"] as? Bool,false);XCTAssertTrue(stale["targetToken"] is NSNull)
        let fresh=try await boundary.execute("get_keypad_ui_state",arguments:[:]);XCTAssertEqual(fresh["clientBindingVerified"] as? Bool,true)
        XCTAssertTrue(rig.events.isEmpty)
        record("AA16 roster refresh invalidates in-flight lookup",["events":rig.events])
    }
    func testClosingBackendDuringBindingLookupCannotRestoreLease() async throws {
        let (rig,boundary,_)=try await setup()
        await boundary.core.pauseNextBinding()
        let pending=Task {try await boundary.execute("get_keypad_ui_state",arguments:[:])}
        try await waitForBinding(boundary);await boundary.close();await boundary.core.releaseBinding()
        let stale=try await pending.value
        XCTAssertEqual(stale["available"] as? Bool,false);XCTAssertTrue(stale["targetToken"] is NSNull)
        let after=try await boundary.execute("get_keypad_ui_state",arguments:[:]);XCTAssertEqual(after["available"] as? Bool,false)
        XCTAssertTrue(rig.events.isEmpty)
        record("AA17 backend close invalidates in-flight lookup",["events":rig.events])
    }
    func testLateFailedLookupDoesNotDiscardNewerWindowLease() async throws {
        let (rig,boundary,_)=try await setup()
        await boundary.core.pauseNextBinding()
        let pending=Task {try await boundary.execute("get_keypad_ui_state",arguments:[:])}
        try await waitForBinding(boundary)
        rig.documentURL="app://-/local/client-new-thread:01000000-0000-0000-0000-000000000003";rig.selectedLinks=[]
        let next=try await boundary.execute("get_keypad_ui_state",arguments:[:]),token=try XCTUnwrap(next["targetToken"] as? String)
        await boundary.core.releaseBinding()
        let stale=try await pending.value;XCTAssertEqual(stale["available"] as? Bool,false)
        let result=try await boundary.execute("toggle_keypad_draft_plan",arguments:["target_token":token,"native_composer":true])
        XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertTrue(rig.plan)
        record("AA18 late lookup preserves newer target lease",["newTargetPlan":rig.plan,"events":rig.events])
    }
}

@MainActor final class NativeNewConversationReplayTests:XCTestCase {
    let old="01000000-0000-0000-0000-000000000001"
    private func settle(_ panel:MicroModel) async throws {
        for _ in 0..<600 {
            if !panel.opening && !panel.controlling && (panel.selectedID == nil || panel.desktopConnected) {return}
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Navigation or native operation did not settle")
    }
    func testNewNavigationThroughDesktopBackendThenAllFourSettings() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+old
        let boundary=NativePanelBoundary(rig),suite="NativeNewConversation."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        await boundary.core.setVisible([old])
        let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground();await panel.refreshActivity();try await settle(panel)
        XCTAssertEqual(panel.currentThreadID,old)
        let captured=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.togglePlanMode"]))
        await boundary.core.navigateOnNewDraft {rig.documentURL="app://-/";rig.homeMarker=true}
        panel.newDraft();try await settle(panel)
        // No panel foreground poll between the request and these assertions.
        XCTAssertTrue(panel.isDraft);XCTAssertNil(panel.currentThreadID);XCTAssertNil(panel.controlError)
        captured();try await settle(panel);XCTAssertEqual(boundary.writes.map(\.0),["new_keypad_thread"])
        for _ in 0..<3 {await panel.refreshActivity();XCTAssertNil(panel.currentThreadID)}
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]))();try await settle(panel)
        }
        panel.setModel(try XCTUnwrap(panel.models.first {$0.id == "gpt-6-luna"}),target:try XCTUnwrap(panel.controlTarget));try await settle(panel)
        XCTAssertNil(panel.controlError);XCTAssertEqual(panel.currentModel,"gpt-6-luna");XCTAssertEqual(panel.currentEffort,"high")
        XCTAssertTrue(panel.fast);XCTAssertEqual(panel.collaborationMode,"plan");XCTAssertNil(panel.currentThreadID)
        XCTAssertEqual(boundary.writes.map(\.0),["new_keypad_thread","set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning","set_keypad_draft_model"])
        XCTAssertTrue(boundary.writes.allSatisfy {$0.1["thread_id"] == nil})
        let reads=await boundary.core.stateReads;XCTAssertEqual(reads,[old])
        ReplayTrace.emit("NEW-CONVERSATION-TRACE",["scenario":"AC01 full backend new draft and four settings","desktopBackend":true,"writes":boundary.writes.map(\.0),"events":rig.events,"currentID":NSNull(),"oldStateReads":reads.count,"model":panel.currentModel,"effort":panel.currentEffort])
    }
    func testUnverifiedBackendNavigationCannotRestoreOldNativeOrStreamIdentity() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+old
        let boundary=NativePanelBoundary(rig),suite="NativeDelayedNew."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        await boundary.core.setVisible([old])
        let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground();try await settle(panel)
        panel.newDraft();try await settle(panel)
        XCTAssertNotNil(panel.controlError)
        for _ in 0..<3 {
            await panel.refreshForeground();await panel.refreshActivity();try await settle(panel)
            XCTAssertNil(panel.currentThreadID);XCTAssertNil(panel.displayedThreadID);XCTAssertNil(panel.controlTarget)
        }
        XCTAssertTrue(rig.events.isEmpty);XCTAssertEqual(boundary.writes.map(\.0),["new_keypad_thread"])
        let reads=await boundary.core.stateReads;XCTAssertEqual(reads,[old])
        rig.documentURL="app://-/hotkey-window/new-thread"
        await panel.refreshForeground();XCTAssertTrue(panel.isDraft);XCTAssertNotNil(panel.controlTarget)
        ReplayTrace.emit("NEW-CONVERSATION-TRACE",["scenario":"AC02 backend unverified navigation and delayed hotkey draft","desktopBackend":true,"oldStateReads":reads.count,"writes":boundary.writes.map(\.0),"events":rig.events,"currentID":NSNull()])
    }
    func testConflictingLiveRouteCannotCompleteNewNavigation() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+old
        let boundary=NativePanelBoundary(rig),suite="NativeConflictingNew."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        await boundary.core.setVisible([old])
        let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground();try await settle(panel)
        panel.newDraft();try await settle(panel)
        rig.selectedLinks=["/local/01000000-0000-0000-0000-000000000002"]
        await panel.refreshForeground();XCTAssertNil(panel.currentThreadID)
        rig.selectedLinks=[]
        await panel.refreshForeground();await panel.refreshActivity();try await settle(panel)
        XCTAssertNil(panel.currentThreadID);XCTAssertNil(panel.controlTarget)
        let reads=await boundary.core.stateReads;XCTAssertEqual(reads,[old]);XCTAssertTrue(rig.events.isEmpty)
        ReplayTrace.emit("NEW-CONVERSATION-TRACE",["scenario":"AC04 real route conflict cannot release pending navigation","desktopBackend":true,"oldStateReads":reads.count,"writes":boundary.writes.map(\.0),"currentID":panel.currentThreadID ?? NSNull() as Any])
    }
    func testConfirmedNewDraftThenUnknownNativeKeepsOldStreamOut() async throws {
        let rig=NativeTraceRig();rig.documentURL="app://-/local/"+old
        let boundary=NativePanelBoundary(rig),suite="NativeLostNew."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        await boundary.core.setVisible([old])
        let panel=MicroModel(settings:Settings(defaults:defaults),client:boundary)
        defer {panel.stop();defaults.removePersistentDomain(forName:suite)}
        await panel.refresh();await panel.refreshForeground();try await settle(panel)
        await boundary.core.navigateOnNewDraft {rig.documentURL="app://-/hotkey-window/new-thread"}
        panel.newDraft();try await settle(panel);XCTAssertTrue(panel.isDraft)
        rig.documentURL="app://-/index.html?initialRoute=/local/"+old
        for _ in 0..<3 {await panel.refreshForeground();await panel.refreshActivity();try await settle(panel)}
        XCTAssertNil(panel.currentThreadID);XCTAssertNil(panel.displayedThreadID);XCTAssertNil(panel.controlTarget)
        let reads=await boundary.core.stateReads;XCTAssertEqual(reads,[old]);XCTAssertTrue(rig.events.isEmpty)
        ReplayTrace.emit("NEW-CONVERSATION-TRACE",["scenario":"AC03 new draft to unreadable native with stale bootstrap and IPC","desktopBackend":true,"oldStateReads":reads.count,"writes":boundary.writes.map(\.0),"currentID":NSNull()])
    }
}
