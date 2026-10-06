import XCTest
@testable import MicroDesktop
@testable import MicroCore

final class NativeModeTests: XCTestCase {
    func testClientSettingsLeaseMatchesRouteAndClientAtDispatchBoundary() {
        let client="client-new-thread:01000000-0000-0000-0000-000000000001"
        let state:[String:Any]=["available":true,"nativeComposer":true,"selectionKnown":true,"draft":false,"threadId":NSNull(),"routeKey":"client:"+client,"clientThreadId":client,"targetToken":"client-lease"]
        let args:[String:Any]=["target_token":"client-lease","native_composer":true]
        XCTAssertTrue(DesktopBackend.acceptsNativeSettings(state,arguments:args))
        var rejected=0
        for (key,value) in [("available",false as Any),("nativeComposer",false),("selectionKnown",false),("draft",true),("threadId","01000000-0000-0000-0000-000000000002"),("routeKey",NSNull()),("routeKey","page:/settings"),("routeKey","host:remote:/local/client-new-thread:01000000-0000-0000-0000-000000000001"),("clientThreadId",NSNull()),("clientThreadId","client-new-thread:01000000-0000-0000-0000-000000000002")] {
            var changed=state;changed[key]=value
            XCTAssertFalse(DesktopBackend.acceptsNativeSettings(changed,arguments:args),key);rejected += 1
        }
        for wrong in [["target_token":"client-lease"],["target_token":"other","native_composer":true]] as [[String:Any]] {
            XCTAssertFalse(DesktopBackend.acceptsNativeSettings(state,arguments:wrong));rejected += 1
        }
        ReplayTrace.emit("DESKTOP-BACKEND-TRACE",["scenario":"X01 client lease at dispatch boundary","rejectedVariants":rejected])
    }
    func testNativeSettingsLeaseRequiresExplicitModeAndExactIdentity() {
        let state:[String:Any]=["available":true,"nativeComposer":true,"draft":false,"selectionKnown":false,"targetToken":"lease-a"]
        let args:[String:Any]=["target_token":"lease-a","native_composer":true]
        XCTAssertTrue(DesktopBackend.acceptsNativeSettings(state,arguments:args))
        XCTAssertFalse(DesktopBackend.acceptsNativeSettings(state,arguments:["target_token":"lease-a"]))
        XCTAssertFalse(DesktopBackend.acceptsNativeSettings(state,arguments:["target_token":"lease-b","native_composer":true]))
        for (key,value) in [("available",false as Any),("selectionKnown",true as Any),("draft",true as Any),("nativeComposer",false as Any),("threadId","01000000-0000-0000-0000-000000000001" as Any)] {
            var changed=state; changed[key]=value
            XCTAssertFalse(DesktopBackend.acceptsNativeSettings(changed,arguments:args),key)
        }
        XCTAssertTrue(DesktopBackend.acceptsNativeSettings(["available":true,"draft":true,"targetToken":"lease-a"],arguments:["target_token":"lease-a"]))
    }
    func testClickingMicroAfterCodexPreservesSubmissionIntent() {
        let focus=SubmissionFocus(controller:10)
        focus.activated(20)
        focus.activated(10)
        XCTAssertTrue(focus.isForeground(10,target:20))
    }
    func testBackgroundFirstPressThenCodexAndMicroAllowsSecondPress() {
        let focus=SubmissionFocus(controller:10)
        focus.activated(30); focus.activated(10)
        XCTAssertFalse(focus.isForeground(10,target:20))
        focus.activated(20); focus.activated(10)
        XCTAssertTrue(focus.isForeground(10,target:20))
        focus.activated(30); focus.activated(10)
        XCTAssertFalse(focus.isForeground(10,target:20))
    }
    func testUnknownFocusAndRestartedTargetNeverAuthorizeSubmit() {
        let focus=SubmissionFocus(controller:10)
        XCTAssertFalse(focus.isForeground(10,target:20))
        focus.activated(20)
        XCTAssertFalse(focus.isForeground(10,target:21))
        XCTAssertFalse(focus.isForeground(nil,target:20))
        XCTAssertFalse(focus.isForeground(10,target:20))
        XCTAssertTrue(focus.isForeground(20,target:20))
    }
    func testFastReadbackSupportsEnglishSimplifiedAndTraditionalLabels() {
        for text in ["Speed Fast", "Speed:Fast", "Speed · Ultrafast", "速度：快速", "速度 · 超快", "速度 極速", "速度 极速"] { XCTAssertEqual(MacUIController.speedValue(text),true,text) }
        for text in ["Speed Standard", "Speed: Standard", "速度 标准", "速度：標準"] { XCTAssertEqual(MacUIController.speedValue(text),false,text) }
        for text in ["", "Speed", "速度", "Faster", "Speed Unknown"] { XCTAssertNil(MacUIController.speedValue(text),text) }
    }
    func testReadContextKeepsIdentityAndHostSeparateWithoutReturningToken() {
        let result=CodexStorage.readContext(["authMethod":"fixture","requiresOpenaiAuth":false])
        XCTAssertEqual(result?.identity,["kind":"execution-storage","authMode":"fixture"])
        XCTAssertEqual(result?.identityKey.count,64)
        XCTAssertEqual(result?.executionHostKey.count,70)
        XCTAssertNotEqual(result?.identityKey,result?.executionHostKey)
        XCTAssertNil(CodexStorage.readContext(["authMethod":"chatgpt","authToken":"invalid"]))
        XCTAssertNil(CodexStorage.readContext([:]))
    }
}
