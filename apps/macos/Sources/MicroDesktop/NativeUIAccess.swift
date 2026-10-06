import AppKit
import ApplicationServices
import MicroCore
import MicroShared

/// OS boundary for native operations. Trace replay replaces only these effects;
/// the same controller, target guards, selection parser and readback run in tests.
struct NativeUIAccess {
    static var live: NativeUIAccess {
        var access = NativeUIAccess()
        access.observe = { try MacUISnapshot.capture(context:$0,permitBackground:true,modelLabels:$1) }
        access.observeRoute = { try DesktopRouteObservation.observe(context: $0) }
        return access
    }
    var observeRoute: ((UIRequestContext) throws -> DesktopRouteObservation.Snapshot?)?
    // Background reads do not grant a foreground mutation. Action captures
    // retain their stricter focus checks before every native effect.
    var observe: ((UIRequestContext,[String]) throws -> MacUISnapshot)?
    var capture: (UIRequestContext,[String]) throws -> MacUISnapshot = { try MacUISnapshot.capture(context:$0,modelLabels:$1) }
    var foreground: () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var activate: (NSRunningApplication) -> Bool = { $0.activate(options:[]) }
    var press: (AXUIElement) throws -> Void = { try MacAX.press($0) }
    var applicationCommand:(Int32,[String],UIRequestContext) throws -> AXNode? = { try MacAX.applicationCommand(pid:$0,names:$1,context:$2) }
    var windows:(Int32,UIRequestContext) throws -> [AXNode] = { pid,context in
        let app=AXUIElementCreateApplication(pid)
        guard let windows=MacAX.value(app,"AXWindows") as? [AXUIElement],windows.count <= 64 else { throw CodexClientError.unavailable("Codex window observation is unavailable.") }
        return try windows.map { window in
            try context.check()
            var owner:pid_t=0
            guard AXUIElementGetPid(window,&owner) == .success,owner == pid else { throw CodexClientError.staleTarget }
            return AXNode(window,parent:nil)
        }
    }
    var expand: (AXUIElement) throws -> Void = { element in
        var actions:CFArray?
        let action = AXUIElementCopyActionNames(element,&actions) == .success && (actions as? [String] ?? []).contains(kAXShowMenuAction as String) ? kAXShowMenuAction:kAXPressAction
        guard AXUIElementPerformAction(element,action as CFString) == .success else { throw CodexClientError.outcomeUnknown }
    }
    var clipboardCount: () -> Int = { NSPasteboard.general.changeCount }
    var clipboard: () -> NativeClipboardState = {
        let board=NSPasteboard.general,count=board.changeCount,text=board.string(forType:.string)
        return .init(changeCount:board.changeCount,text:count == board.changeCount ? text:nil)
    }
    var set: (AXUIElement,String,CFTypeRef) throws -> Void = { try MacAX.set($0,$1,$2) }
    var shortcut: (String) throws -> MacShortcut = { try MacShortcut.configured($0) }
    var send: (MacShortcut,Int32,() throws -> Void) throws -> Void = { try $0.send(to:$1,check:$2) }
    var typePreset: (ComposerTextPreset,Int32,() throws -> Void) throws -> Void = { preset,pid,check in
        let units=Array(preset.text.utf16)
        guard let down=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true),
              let up=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:false) else {throw CodexClientError.unavailable("Native text input is unavailable.")}
        down.flags=[];up.flags=[]
        units.withUnsafeBufferPointer {
            down.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress!)
            up.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress!)
        }
        try check()
        down.postToPid(pid);up.postToPid(pid)
    }
    var observeActivation = true
}
