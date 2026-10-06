import XCTest
@testable import MicroDesktop

final class WorkspaceActionTests: XCTestCase {
    func testSettingsSkillsAndTasksNativeLinksRequireTheirExactObservedPages() async throws {
        for page in [WorkspaceActions.CodexPage.settings,.skills,.automations] {
            var opened:[String]=[],reads=0
            let result=try await WorkspaceActions.codexPage(page,open:{ opened.append($0.absoluteString) },observe:{
                reads += 1
                return reads == 1 ? ["selectionKnown":true,"routeKey":"thread:fixture"] : ["selectionKnown":true,"routeKey":"page:/"+page.rawValue]
            },pause:{})
            XCTAssertEqual(opened,["codex://"+page.rawValue]);XCTAssertEqual(reads,2)
            XCTAssertEqual(result["navigation_verified"] as? Bool,true)
            ReplayTrace.emit("PAGE-TRACE",["destination":page.rawValue,"launch":1,"observed":2,"verified":true])
        }
        XCTAssertTrue(WorkspaceActions.CodexPage.settings.matches(["selectionKnown":true,"routeKey":"page:/settings/general"]))
        XCTAssertFalse(WorkspaceActions.CodexPage.settings.matches(["selectionKnown":true,"routeKey":"page:/settings-fake"]))
        XCTAssertFalse(WorkspaceActions.CodexPage.skills.matches(["selectionKnown":false,"routeKey":"page:/skills"]))
        XCTAssertFalse(WorkspaceActions.CodexPage.automations.matches(["selectionKnown":true,"routeKey":"page:/automations-fake"]))
        XCTAssertFalse(WorkspaceActions.CodexPage.automations.matches(["selectionKnown":true,"routeKey":"page:/automations/other"]))
    }
    func testUnobservedPageLaunchIsNotReportedVerifiedOrRetried() async throws {
        var launches=0,reads=0
        let result=try await WorkspaceActions.codexPage(.settings,open:{ _ in launches += 1 },observe:{
            reads += 1;return ["available":false,"selectionKnown":true,"routeKey":"conflict"]
        },pause:{})
        XCTAssertEqual(launches,1);XCTAssertEqual(reads,6)
        XCTAssertEqual(result["launch_requested"] as? Bool,true)
        XCTAssertEqual(result["navigation_verified"] as? Bool,false)
    }
    func testRejectedPageLaunchDoesNotReadOrRetry() async {
        var launches=0,reads=0
        do {
            _ = try await WorkspaceActions.codexPage(.skills,open:{ _ in launches += 1;throw CocoaError(.fileNoSuchFile) },observe:{reads += 1;return [:]},pause:{})
            XCTFail("Rejected launch must fail")
        } catch {}
        XCTAssertEqual(launches,1);XCTAssertEqual(reads,0)
    }
    func testDeveloperKeyUsesFixedHTTPSDestinationOnce() throws {
        var destinations:[URL]=[]
        let result=try WorkspaceActions.developerSite { destinations.append($0); return true }
        XCTAssertEqual(destinations.map(\.absoluteString),["https://developers.openai.com/"])
        XCTAssertEqual(result["launch_requested"] as? Bool,true)
        XCTAssertNil(result["verified"])
    }
    func testRejectedLaunchDoesNotRetry() {
        var calls=0
        XCTAssertThrowsError(try WorkspaceActions.developerSite { _ in calls += 1; return false })
        XCTAssertEqual(calls,1)
    }
    func testFolderWithSpacesAndURLCharactersIsOpenedAsLocalDirectory() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("MicroWorkspaceTests-"+UUID().uuidString)
        let folder=base.appendingPathComponent("项目 #1 ? notes")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        var destinations:[URL]=[]
        let result=try WorkspaceActions.folder(folder.path) { destinations.append($0); return true }
        XCTAssertEqual(destinations.count,1)
        XCTAssertTrue(destinations[0].isFileURL)
        XCTAssertEqual(destinations[0].path,folder.resolvingSymlinksInPath().path)
        XCTAssertNil(URLComponents(url:destinations[0],resolvingAgainstBaseURL:false)?.query)
        XCTAssertNil(URLComponents(url:destinations[0],resolvingAgainstBaseURL:false)?.fragment)
        XCTAssertEqual(result["launch_requested"] as? Bool,true)
    }
    func testInvalidMissingAndRegularFileDestinationsNeverLaunch() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("MicroWorkspaceFile-"+UUID().uuidString)
        try Data("fixture".utf8).write(to:file)
        defer { try? FileManager.default.removeItem(at:file) }
        var calls=0
        for path in ["relative-folder","https://example.invalid/project",file.path,file.path+"-missing","/tmp/invalid\0path"] {
            XCTAssertThrowsError(try WorkspaceActions.folder(path) { _ in calls += 1; return true },path)
        }
        XCTAssertEqual(calls,0)
    }
}
