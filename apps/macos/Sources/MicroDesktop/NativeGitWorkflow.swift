import AppKit
import ApplicationServices
import MicroCore

/// Opens the same reviewable workflow as Codex's command. Creation stays in
/// the native form; neither a selected menu item nor an open form is a commit/PR.
enum NativeGitWorkflow {
    enum Action:String {
        case branch, pullRequest, draftPullRequest, commit, mergePullRequest
        var titles:[String] {
            switch self {
            case .branch:return ["Create branch","创建分支","建立分支"]
            case .pullRequest:return ["Create PR","创建 PR","建立 PR","建立提取要求"]
            case .draftPullRequest:return ["Create draft PR","创建草稿 PR","建立草稿 PR"]
            case .commit:return ["Commit or push","提交或推送"]
            case .mergePullRequest:return ["Merge PR","合并 PR","合併 PR"]
            }
        }
    }
    static let branchTitles=["Work here","在此工作","在此處工作"]
    static let branchFields=["Branch name","分支名称","分支名稱"]
    static let createBranch=["Create","创建","建立"]
    static let prTitles=["Create PR","创建 PR","建立 PR"]
    static let createPR=["Create PR","创建 Pull Request","建立 PR"]
    static let createDraftPR=["Create draft PR","创建草稿 PR","建立草稿提取要求","建立草稿 PR"]
    enum Stage:String {case branchSetup, commitForm, pullRequestForm, mergeConfirmation}
    static let commitTitles=["Commit or push","提交或推送","送交或推送"]
    static let commitChoices=[["Commit","提交"],["Commit and push","提交并推送","提交並推送","提交並推播"],["Push","推送"]]
    static let mergeTitles=["Merge pull request","合并 Pull Request","合併 Pull Request"]
    static let squashConfirm=["Squash and merge","压缩并合并","壓縮並合併"]
    static let commitConfirm=["Create merge commit","创建合并提交","建立合併提交"]

    static func mergeMethod(_ state:MacUISnapshot) -> String? {
        var method:String?
        let form=NativeCommandMenu.dialog(state,named:mergeTitles) { parent in
            let children=state.nodes.indices.filter {MacUISnapshot.within($0,ancestor:parent,nodes:state.nodes)}
            guard state.unique(children,matching:{$0.role == "AXButton" && $0.named(["Cancel","取消"])}) != nil,
                  let confirm=state.unique(children,matching:{$0.role == "AXButton" && $0.rect.width > 0 && $0.rect.height > 0 && $0.named(squashConfirm+commitConfirm)}) else {return false}
            // The repository can permit just one method, in which case there
            // is no method picker. The final button identifies the native choice.
            method=confirm.named(squashConfirm) ? "squash":"merge"
            return true
        }
        return form == nil ? nil:method
    }

    static func stage(_ state:MacUISnapshot,action:Action) -> Stage? {
        if action == .mergePullRequest {return mergeMethod(state) == nil ? nil:.mergeConfirmation}
        // Commit and both PR commands can first require a worktree branch.
        // Leave that form intact and distinguish it from the eventual PR form.
        if NativeCommandMenu.dialog(state,named:branchTitles,requiring: { parent in
                let children=state.nodes.indices.filter { MacUISnapshot.within($0,ancestor:parent,nodes:state.nodes) }
                return state.unique(children,matching:{$0.role == "AXTextField" && $0.named(branchFields)}) != nil &&
                    state.unique(children,matching:{$0.button && $0.named(createBranch)}) != nil
            }) != nil {return .branchSetup}
        if action == .branch {return nil}
        if action == .commit {
            return NativeCommandMenu.dialog(state,named:commitTitles) { parent in
                let children=state.nodes.indices.filter { $0 == parent || MacUISnapshot.within($0,ancestor:parent,nodes:state.nodes) }
                // In push-only mode the message and include-unstaged checkbox
                // are absent. The three distinct native choices remain, with
                // unavailable choices disabled; never press any of them here.
                return children.contains {state.nodes[$0].classes.contains("command-menu-dialog")} &&
                    commitChoices.allSatisfy {NativeCommandMenu.item(state,in:parent,names:$0) != nil}
            } != nil ? .commitForm:nil
        }
        return NativeCommandMenu.dialog(state,named:prTitles) { parent in
            let children=state.nodes.indices.filter { MacUISnapshot.within($0,ancestor:parent,nodes:state.nodes) }
            return state.unique(children,matching:{$0.role == "AXTextField" && $0.identifier == "create-pr-title"}) != nil &&
                state.unique(children,matching:{$0.role == "AXTextArea" && $0.identifier == "create-pr-message"}) != nil &&
                NativeCommandMenu.item(state,in:parent,names:action == .draftPullRequest ? createDraftPR:createPR,selected:true) != nil &&
                NativeCommandMenu.item(state,in:parent,names:action == .draftPullRequest ? createPR:createDraftPR,selected:true) == nil
        } != nil ? .pullRequestForm:nil
    }
    static func open(_ action:Action,before:MacUISnapshot,io:NativeUIAccess,context:UIRequestContext,
                     capture:() throws -> MacUISnapshot,mutation:() -> Void) throws -> MacUISnapshot {
        try NativeCommandMenu.perform(before:before,io:io,context:context,capture:capture,mutation:mutation,
            select:{state,palette in
                // A chat can have the same title as a command. Only the
                // registered Project group can authorize a Git workflow.
                guard let project=NativeCommandMenu.projectGroup(state,in:palette) else {return nil}
                return NativeCommandMenu.item(state,in:project,names:action.titles)
            },completed:{stage($0,action:action) != nil})
    }
}
