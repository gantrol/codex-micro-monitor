import AppKit
import MicroCore
import MicroShared

enum NativePresetText {
    static func replacing(_ text:String,range:NSRange,preset:ComposerTextPreset) -> String? {
        let units=Array(text.utf16),count=units.count
        guard range.location >= 0,range.length >= 0,range.location <= count,range.length <= count-range.location else {return nil}
        func boundary(_ offset:Int) -> Bool {
            offset == 0 || offset == count || !((0xD800...0xDBFF).contains(units[offset-1]) && (0xDC00...0xDFFF).contains(units[offset]))
        }
        guard boundary(range.location),boundary(range.location+range.length) else {return nil}
        return (text as NSString).replacingCharacters(in:range,with:preset.text)
    }
    static func insert(_ preset:ComposerTextPreset,before:MacUISnapshot,io:NativeUIAccess,context:UIRequestContext,
                       capture:(_ preserveText:Bool) throws -> MacUISnapshot,mutation:() -> Void) throws -> MacUISnapshot {
        guard before.thread != nil || before.draft,let editor=before.editor,editor.text != nil,
              before.topLevelMenus.isEmpty,before.composerMenuItems.isEmpty,before.menuItems.isEmpty else {throw CodexClientError.staleTarget}
        _ = try capture(true)
        if !editor.focused {try io.set(editor.element,"AXFocused",kCFBooleanTrue)}
        let focusEnd=ProcessInfo.processInfo.systemUptime+0.6
        var focused:MacUISnapshot?
        repeat {
            let state=try capture(true)
            if state.editor?.focused == true {focused=state;break}
            Thread.sleep(forTimeInterval:0.02)
        } while ProcessInfo.processInfo.systemUptime < focusEnd
        guard let focused,let input=focused.editor,let text=input.text,let selection=input.selectedTextRange,
              let expected=replacing(text,range:selection,preset:preset) else {throw CodexClientError.unavailable("The native composer selection is unavailable.")}
        let caret=NSRange(location:selection.location+preset.text.utf16.count,length:0)
        mutation();try io.typePreset(preset,before.app.processIdentifier) {
            try context.check()
            let current=try capture(true)
            guard current.editor?.focused == true,current.editor?.selectedTextRange == selection,
                  current.settings as NSDictionary == focused.settings as NSDictionary,
                  current.topLevelMenus.isEmpty,current.composerMenuItems.isEmpty,current.menuItems.isEmpty,
                  io.foreground() == before.app.processIdentifier else {throw CodexClientError.staleTarget}
        }
        let end=ProcessInfo.processInfo.systemUptime+2.5
        repeat {
            try context.check()
            let state=try capture(false)
            if state.editor?.focused == true,state.editor?.text?.utf16.elementsEqual(expected.utf16) == true,state.editor?.selectedTextRange == caret {return state}
            Thread.sleep(forTimeInterval:0.03)
        } while ProcessInfo.processInfo.systemUptime < end
        throw CodexClientError.outcomeUnknown
    }
}
