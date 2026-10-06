import XCTest
import AppKit
import ApplicationServices
@testable import MicroDesktop

private final class GitWorkflowRig:@unchecked Sendable {
    static let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    let elements=(0..<100).map {AXUIElementCreateApplication(Int32(720000+$0))}
    var thread=a,locale=0,action:NativeGitWorkflow.Action = .branch
    var menu=false,form=false,foreignModal=false,commandAvailable=true,entryAvailable=true,entryEnabled=true,duplicateEntry=false
    var createForm=true,wrongForm=false,wrongPRSelection=false,initialComposer=true
    var branchPrerequisite=false,commitPushOnly=false,commitCorruption=0
    var projectAvailable=true,duplicateProject=false,sameNamedChat=false
    var mergeSquash=true,mergeMethodPicker=true,mergeCorruption=0
    var afterMenu:(()->Void)?,afterCommand:(()->Void)?,events:[String]=[]
    var labels:[String] {
        switch action {
        case .branch:return ["Create branch","创建分支","建立分支","建立分支"]
        case .pullRequest:return ["Create PR","创建 PR","建立 PR","建立提取要求"]
        case .draftPullRequest:return ["Create draft PR","创建草稿 PR","建立草稿 PR","建立草稿 PR"]
        case .commit:return ["Commit or push","提交或推送","提交或推送","提交或推送"]
        case .mergePullRequest:return ["Merge PR","合并 PR","合併 PR","合併 PR"]
        }
    }
    func node(_ id:Int,_ parent:Int?,_ role:String,_ name:String="",identifier:String="",classes:[String]=[],selected:Bool=false,enabled:Bool=true) -> AXNode {
        AXNode(element:elements[id],parent:parent,role:role,name:name,identifier:identifier,enabled:enabled,selected:selected,classes:classes)
    }
    func snapshot() -> MacUISnapshot {
        var nodes=[node(0,nil,"AXWindow"),node(1,0,"AXGroup"),AXNode(element:elements[2],parent:1,role:"AXTextArea",text:"unsubmitted draft",classes:["ProseMirror"])]
        if menu {
            nodes.append(node(3,0,"AXDialog",["Command menu","命令菜单","指令選單","指令功能表"][locale],classes:["global-command-menu-dialog"]))
            nodes.append(node(4,3,"AXGroup",projectAvailable ? ["Project","项目","項目","專案"][locale]:"Other"))
            if entryAvailable {
                // Shortcut text may be in the row's full name. The exact
                // localized title belongs to a scoped text child.
                nodes.append(node(5,4,"AXRow","command with shortcut",enabled:entryEnabled))
                nodes.append(node(6,5,"AXStaticText",labels[locale]))
                if duplicateEntry {nodes.append(node(7,4,"AXRow",labels[locale]))}
            }
            if sameNamedChat {
                let group=nodes.count;nodes.append(node(20,3,"AXGroup","Chats"))
                nodes.append(node(21,group,"AXRow",labels[locale]))
            }
            if duplicateProject {nodes.append(node(22,3,"AXGroup",["Project","项目","項目","專案"][locale]))}
        } else if form {
            if wrongForm {nodes.append(node(3,0,"AXDialog","Settings"))}
            else if action == .branch || branchPrerequisite {
                nodes.append(node(3,0,"AXDialog",["Work here","在此工作","在此處工作","在此處工作"][locale]))
                nodes.append(node(4,3,"AXTextField",["Branch name","分支名称","分支名稱","分支名稱"][locale]))
                nodes.append(node(5,3,"AXButton",["Create","创建","建立","建立"][locale]))
            } else if action == .mergePullRequest {
                nodes.append(node(3,0,"AXDialog",["Merge pull request","合并 Pull Request","合併 Pull Request","合併 Pull Request"][locale]))
                if mergeCorruption != 1 {nodes.append(node(4,3,"AXButton",["Cancel","取消","取消","取消"][locale]))}
                let confirm=mergeSquash ? ["Squash and merge","压缩并合并","壓縮並合併","壓縮並合併"][locale]:["Create merge commit","创建合并提交","建立合併提交","建立合併提交"][locale]
                nodes.append(node(5,3,"AXButton",confirm))
                if mergeCorruption == 2 {nodes.append(node(6,3,"AXButton",mergeSquash ? "Create merge commit":"Squash and merge"))}
                if mergeCorruption == 3 {nodes.append(node(6,3,"AXButton",confirm))}
                if mergeMethodPicker {nodes.append(node(7,3,"AXComboBox",["Merge method","合并方法","合併方法","合併方法"][locale]))}
            } else if action == .commit {
                nodes.append(node(3,0,"AXDialog",["Commit or push","提交或推送","提交或推送","送交或推送"][locale]))
                nodes.append(node(4,3,"AXGroup",classes:commitCorruption == 1 ? []:["command-menu-dialog"]))
                nodes.append(node(5,4,"AXList"))
                nodes.append(node(6,5,"AXRow",["Commit","提交","提交","提交"][locale],selected:!commitPushOnly,enabled:!commitPushOnly))
                nodes.append(node(7,5,"AXRow",["Commit and push","提交并推送","提交並推送","提交並推播"][locale],enabled:!commitPushOnly))
                if commitCorruption != 2 {nodes.append(node(8,5,"AXRow",["Push","推送","推送","推送"][locale],selected:commitPushOnly))}
                if commitCorruption == 3 {nodes.append(node(9,5,"AXRow",["Commit","提交","提交","提交"][locale]))}
                if !commitPushOnly {
                    nodes.append(node(10,4,"AXTextArea",["Commit message","提交信息","提交訊息","提交訊息"][locale]))
                    nodes.append(node(11,4,"AXCheckBox",identifier:"commit-include-unstaged-changes"))
                }
            } else {
                nodes.append(node(3,0,"AXDialog",["Create PR","创建 PR","建立 PR","建立 PR"][locale]))
                nodes.append(node(4,3,"AXTextField","Title",identifier:"create-pr-title"))
                nodes.append(node(5,3,"AXTextArea","Message",identifier:"create-pr-message"))
                nodes.append(node(6,3,"AXList"))
                let draft=(action == .draftPullRequest) != wrongPRSelection
                nodes.append(node(7,6,"AXRow",["Create PR","创建 Pull Request","建立 PR","建立 PR"][locale],selected:!draft))
                nodes.append(node(8,6,"AXRow",["Create draft PR","创建草稿 PR","建立草稿 PR","建立草稿提取要求"][locale],selected:draft))
            }
        }
        if foreignModal {nodes.append(node(89,0,"AXDialog","Permission request"))}
        let composer=initialComposer && !menu && !form && !foreignModal
        return MacUISnapshot(app:NSRunningApplication.current,root:elements[0],window:elements[0],nodes:nodes,
            composer:composer ? 2:nil,container:composer ? 1:nil,thread:thread,draft:false,route:"thread:"+thread,
            selectionKnown:true,nativeFallback:false,selectedSidebar:nil,controls:[],menuItems:[],blocked:menu || form || foreignModal,modelLabels:[])
    }
    var io:NativeUIAccess {
        var io=NativeUIAccess();io.observeActivation=false
        io.shortcut={_ in throw NSError(domain:"MicroReplay.NoConfiguredShortcut",code:1)}
        io.foreground={NSRunningApplication.current.processIdentifier};io.activate={_ in XCTFail("No activation expected");return false}
        io.capture={ [self] _,_ in snapshot() }
        io.applicationCommand={ [self] _,names,_ in
            XCTAssertEqual(names,NativeCommandMenu.openMenu)
            return commandAvailable ? node(90,nil,"AXMenuItem","Open command menu"):nil
        }
        io.press={ [self] element in
            if CFEqual(element,elements[90]) {events.append("open-command-menu");menu=true;afterMenu?()}
            else if CFEqual(element,elements[5]) && menu {events.append("choose:"+action.rawValue);menu=false;form=createForm;afterCommand?()}
            else {XCTFail("Must not submit a native Git form")}
        }
        io.send={ [self] key,_,check in try check();XCTAssertEqual(key.key,53);XCTAssertTrue(menu);events.append("close-owned-menu");menu=false }
        io.set={_,_,_ in XCTFail("Must not type into Git forms or modify selection")}
        return io
    }
    var operation:String {[NativeGitWorkflow.Action.branch:"open_keypad_branch",.commit:"open_keypad_commit",.mergePullRequest:"open_keypad_merge_pull_request",.pullRequest:"open_keypad_pull_request",.draftPullRequest:"open_keypad_draft_pull_request"][action]!}
    func open(_ controller:MacUIController,id:String?=nil) async throws -> [String:Any] {
        let before=try await controller.execute("get_keypad_ui_state",arguments:[:])
        return try await controller.execute(operation,arguments:["thread_id":id ?? Self.a,"target_token":try XCTUnwrap(before["targetToken"] as? String)])
    }
    func record(_ scenario:String) {
        let data:[String:Any]=["scenario":scenario,"events":events,"formOpen":form,"menuOpen":menu,"workflow":action.rawValue,"locale":locale]
        ReplayTrace.emit("GIT-WORKFLOW-TRACE",data)
    }
}

final class NativeGitWorkflowTests:XCTestCase {
    func testBranchWorkflowOpensWithoutCreatingOrChangingRepositoryInFourLocales() async throws {
        for locale in 0..<4 {
            let rig=GitWorkflowRig();rig.locale=locale;rig.initialComposer=false
            let result=try await rig.open(MacUIController(io:rig.io))
            XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["workflowOpened"] as? Bool,true)
            XCTAssertEqual(result["mutationCompleted"] as? Bool,false);XCTAssertEqual(result["threadId"] as? String,GitWorkflowRig.a)
            XCTAssertEqual(rig.events,["open-command-menu","choose:branch"]);XCTAssertTrue(rig.form)
            XCTAssertEqual(result["workflowStage"] as? String,"branchSetup")
            rig.record("G01 branch form locale \(locale)")
        }
    }
    func testPullRequestAndDraftCommandsReadBackDifferentSelectedActionsInFourLocales() async throws {
        for action in [NativeGitWorkflow.Action.pullRequest,.draftPullRequest] {
            for locale in 0..<4 {
                let rig=GitWorkflowRig();rig.action=action;rig.locale=locale
                let result=try await rig.open(MacUIController(io:rig.io))
                XCTAssertEqual(result["workflow"] as? String,action.rawValue);XCTAssertEqual(result["mutationCompleted"] as? Bool,false)
                XCTAssertEqual(rig.events,["open-command-menu","choose:"+action.rawValue]);XCTAssertTrue(rig.form)
                XCTAssertNil((result["state"] as? [String:Any])?["targetToken"] as? String)
                XCTAssertEqual(result["workflowStage"] as? String,"pullRequestForm");XCTAssertEqual(result["prDefaultVerified"] as? Bool,true)
                rig.record("G02 PR default \(action.rawValue) locale \(locale)")
            }
        }
    }
    func testMissingDisabledAndDuplicateCommandsNeverChooseFallbackOrSubmit() async {
        for scenario in 0..<3 {
            let rig=GitWorkflowRig();rig.entryAvailable=scenario != 0;rig.entryEnabled=scenario != 1;rig.duplicateEntry=scenario == 2
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Unavailable workflow must fail")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","close-owned-menu"]);XCTAssertFalse(rig.form)
            rig.record("G03 unavailable command \(scenario)")
        }
    }
    func testTargetChangesBeforeAndAfterCommandNeverConfirmOtherChatOrReplay() async {
        for after in [false,true] {
            let rig=GitWorkflowRig()
            if after {rig.afterCommand={rig.thread=GitWorkflowRig.b}} else {rig.afterMenu={rig.thread=GitWorkflowRig.b}}
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Changed target must fail")} catch {}
            XCTAssertEqual(rig.events,after ? ["open-command-menu","choose:branch"]:["open-command-menu"])
            rig.record("G04 target changed after command \(after)")
        }
    }
    func testMissingWrongFormsAndWrongPRDefaultCannotConfirmSuccess() async {
        for scenario in 0..<3 {
            let rig=GitWorkflowRig();rig.action = .draftPullRequest
            rig.createForm=scenario != 0;rig.wrongForm=scenario == 1;rig.wrongPRSelection=scenario == 2
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Wrong workflow must stay unknown")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","choose:draftPullRequest"])
            rig.record("G05 incorrect form \(scenario)")
        }
    }
    func testPermissionOverlayIsNeverDismissedOrTreatedAsPalette() async {
        let rig=GitWorkflowRig();rig.afterMenu={rig.foreignModal=true}
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Permission modal must stop input")} catch {}
        XCTAssertEqual(rig.events,["open-command-menu"]);XCTAssertTrue(rig.foreignModal)
        rig.record("G06 permission overlay")
    }
    func testMissingApplicationCommandAndMismatchedThreadHaveZeroActions() async {
        for missing in [false,true] {
            let rig=GitWorkflowRig();rig.commandAvailable = !missing
            do {_ = try await rig.open(MacUIController(io:rig.io),id:missing ? nil:GitWorkflowRig.b);XCTFail("No authority")} catch {}
            XCTAssertTrue(rig.events.isEmpty)
        }
    }
    func testCommitAndPushOnlyFormsInFourLocalesNeverSubmitAnyChoice() async throws {
        for locale in 0..<4 {
            for pushOnly in [false,true] {
                let rig=GitWorkflowRig();rig.action = .commit;rig.locale=locale;rig.commitPushOnly=pushOnly
                let result=try await rig.open(MacUIController(io:rig.io))
                XCTAssertEqual(result["workflowStage"] as? String,"commitForm")
                XCTAssertEqual(result["mutationCompleted"] as? Bool,false)
                XCTAssertEqual(result["prDefaultVerified"] as? Bool,false)
                XCTAssertEqual(rig.events,["open-command-menu","choose:commit"])
                XCTAssertTrue(rig.form)
                rig.record("G07 commit form locale \(locale), push only \(pushOnly)")
            }
        }
    }
    func testCommitAndPRBranchPrerequisitesAreExplicitStagesWithoutClaimingPRDefault() async throws {
        for action in [NativeGitWorkflow.Action.commit,.pullRequest,.draftPullRequest] {
            for locale in 0..<4 {
                let rig=GitWorkflowRig();rig.action=action;rig.branchPrerequisite=true;rig.locale=locale
                let result=try await rig.open(MacUIController(io:rig.io))
                XCTAssertEqual(result["workflow"] as? String,action.rawValue)
                XCTAssertEqual(result["workflowStage"] as? String,"branchSetup")
                XCTAssertEqual(result["prDefaultVerified"] as? Bool,false)
                XCTAssertEqual(result["mutationCompleted"] as? Bool,false)
                XCTAssertEqual(rig.events,["open-command-menu","choose:"+action.rawValue])
                XCTAssertTrue(rig.form)
                rig.record("G08 branch prerequisite \(action.rawValue), locale \(locale)")
            }
        }
    }
    func testCommitDialogRequiresSpecificTitleContainerAndUniqueChoices() async {
        for corruption in 0..<4 {
            let rig=GitWorkflowRig();rig.action = .commit;rig.commitCorruption=corruption;rig.wrongForm=corruption == 0
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Unknown commit form must not pass")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","choose:commit"]);XCTAssertTrue(rig.form)
            rig.record("G09 invalid commit form \(corruption)")
        }
    }
    func testCommitCommandUnavailableDisabledAndDuplicateNeverSelectOtherGitAction() async {
        for scenario in 0..<3 {
            let rig=GitWorkflowRig();rig.action = .commit
            rig.entryAvailable=scenario != 0;rig.entryEnabled=scenario != 1;rig.duplicateEntry=scenario == 2
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Unavailable commit command must fail")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","close-owned-menu"]);XCTAssertFalse(rig.form)
            rig.record("G10 unavailable commit \(scenario)")
        }
    }
    func testCommitTargetSwitchBeforeAndAfterSelectionNeverRetriesOrDismissesOtherForm() async {
        for after in [false,true] {
            let rig=GitWorkflowRig();rig.action = .commit
            if after {rig.afterCommand={rig.thread=GitWorkflowRig.b}} else {rig.afterMenu={rig.thread=GitWorkflowRig.b}}
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Changed commit target must fail")} catch {}
            XCTAssertEqual(rig.events,after ? ["open-command-menu","choose:commit"]:["open-command-menu"])
            rig.record("G11 commit target changed after selection \(after)")
        }
    }
    func testPermissionOverlayAboveCommitFormPreventsSuccessAndStaysUntouched() async {
        let rig=GitWorkflowRig();rig.action = .commit;rig.afterCommand={rig.foreignModal=true}
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Permission overlay must prevent success")} catch {}
        XCTAssertEqual(rig.events,["open-command-menu","choose:commit"]);XCTAssertTrue(rig.foreignModal)
        rig.record("G12 permission above commit form")
    }

    func testGitCommandsIgnoreIdenticallyNamedChatResultsOutsideProjectGroup() async throws {
        for action in [NativeGitWorkflow.Action.branch,.commit,.pullRequest,.draftPullRequest,.mergePullRequest] {
            let rig=GitWorkflowRig();rig.action=action;rig.sameNamedChat=true
            let result=try await rig.open(MacUIController(io:rig.io))
            XCTAssertEqual(result["verified"] as? Bool,true)
            XCTAssertEqual(rig.events,["open-command-menu","choose:"+action.rawValue])
            rig.record("G13 same-named chat and \(action.rawValue)")
        }
    }
    func testMissingOrDuplicateProjectGroupCannotAuthorizeSameNamedChat() async {
        for scenario in 0..<3 {
            let rig=GitWorkflowRig();rig.action = .commit;rig.sameNamedChat=true
            rig.projectAvailable=scenario == 2;rig.entryAvailable=scenario != 1;rig.duplicateProject=scenario == 2
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Missing or ambiguous command group must fail")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","close-owned-menu"]);XCTAssertFalse(rig.form)
            rig.record("G14 project group unavailable \(scenario)")
        }
    }

    func testMergeConfirmationPreservesNativeMethodAndNeverSubmitsInFourLocales() async throws {
        for locale in 0..<4 {
            for squash in [false,true] {
                let rig=GitWorkflowRig();rig.action = .mergePullRequest;rig.locale=locale
                rig.mergeSquash=squash;rig.mergeMethodPicker=squash
                let result=try await rig.open(MacUIController(io:rig.io))
                XCTAssertEqual(result["workflowStage"] as? String,"mergeConfirmation")
                XCTAssertEqual(result["mergeMethod"] as? String,squash ? "squash":"merge")
                XCTAssertEqual(result["mergeCompleted"] as? Bool,false)
                XCTAssertEqual(result["pullRequestIdentityVerified"] as? Bool,false)
                XCTAssertEqual(result["mutationCompleted"] as? Bool,false)
                XCTAssertNil(result["pullRequestId"]);XCTAssertNil(result["pullRequestURL"])
                XCTAssertEqual(rig.events,["open-command-menu","choose:mergePullRequest"])
                XCTAssertTrue(rig.form)
                rig.record("G15 merge confirmation locale \(locale), squash \(squash)")
            }
        }
    }
    func testMergeUnavailableDisabledOrDuplicateCommandDoesNotChooseFallback() async {
        for scenario in 0..<3 {
            let rig=GitWorkflowRig();rig.action = .mergePullRequest
            rig.entryAvailable=scenario != 0;rig.entryEnabled=scenario != 1;rig.duplicateEntry=scenario == 2
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Unavailable merge command must fail")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","close-owned-menu"]);XCTAssertFalse(rig.form)
            rig.record("G16 unavailable merge command \(scenario)")
        }
    }
    func testWrongAmbiguousMergeFormsAndBranchFormCannotConfirmMergeWorkflow() async {
        for scenario in 0..<5 {
            let rig=GitWorkflowRig();rig.action = .mergePullRequest
            rig.wrongForm=scenario == 0;rig.mergeCorruption=scenario;rig.branchPrerequisite=scenario == 4
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Wrong merge form must remain unknown")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","choose:mergePullRequest"]);XCTAssertTrue(rig.form)
            rig.record("G17 invalid merge confirmation \(scenario)")
        }
    }
    func testMergeTargetChangesBeforeAndAfterCommandKeepOtherChatUntouched() async {
        for after in [false,true] {
            let rig=GitWorkflowRig();rig.action = .mergePullRequest
            if after {rig.afterCommand={rig.thread=GitWorkflowRig.b}} else {rig.afterMenu={rig.thread=GitWorkflowRig.b}}
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Changed merge target must fail")} catch {}
            XCTAssertEqual(rig.events,after ? ["open-command-menu","choose:mergePullRequest"]:["open-command-menu"])
            rig.record("G18 merge target changed after command \(after)")
        }
    }
    func testPermissionAboveMergeFormPreventsConfirmationWithoutDismissingAnything() async {
        let rig=GitWorkflowRig();rig.action = .mergePullRequest;rig.afterCommand={rig.foreignModal=true}
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Permission modal must prevent success")} catch {}
        XCTAssertEqual(rig.events,["open-command-menu","choose:mergePullRequest"]);XCTAssertTrue(rig.foreignModal)
        rig.record("G19 permission above merge confirmation")
    }
    func testMergeMissingApplicationCommandAndMismatchedThreadHaveNoEffects() async {
        for missing in [false,true] {
            let rig=GitWorkflowRig();rig.action = .mergePullRequest;rig.commandAvailable = !missing
            do {_ = try await rig.open(MacUIController(io:rig.io),id:missing ? nil:GitWorkflowRig.b);XCTFail("No authority")} catch {}
            XCTAssertTrue(rig.events.isEmpty)
            rig.record("G20 merge unavailable authority \(missing)")
        }
    }

}
