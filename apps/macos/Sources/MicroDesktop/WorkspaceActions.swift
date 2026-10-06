import Foundation

// The destination is fixed or comes from a validated exact thread record.
// Launch Services acceptance is not a claim about the destination's contents.
enum WorkspaceActions {
    static let developerURL = URL(string: "https://developers.openai.com/")!

    enum CodexPage: String {
        case settings, skills, automations
        case microSettings = "settings/codex-micro"
        var url:URL { URL(string:"codex://"+rawValue)! }
        func matches(_ state:[String:Any]) -> Bool {
            guard state["selectionKnown"] as? Bool == true,let route=state["routeKey"] as? String else { return false }
            let base="page:/"+rawValue
            return route == base || (self == .settings && route.hasPrefix(base+"/"))
        }
    }
    static func codexPage(_ page:CodexPage, open:(URL) async throws -> Void,
                          observe:() async throws -> [String:Any],
                          pause:() async throws -> Void = { try await Task.sleep(for:.milliseconds(150)) }) async throws -> [String:Any] {
        try Task.checkCancellation()
        try await open(page.url)
        var result:[String:Any]=["launch_requested":true,"url":page.url.absoluteString,"navigation_verified":false]
        do {
            for attempt in 0..<6 {
                try Task.checkCancellation()
                let state=try await observe()
                if page.matches(state) { result["navigation_verified"]=true;result["foreground"]=state;break }
                if attempt < 5 { try await pause() }
            }
        } catch { result["followupError"]=error.localizedDescription }
        return result
    }

    static func developerSite(open: (URL) -> Bool) throws -> [String: Any] {
        try launch(developerURL, open: open)
    }

    static func folder(_ path: String, open: (URL) -> Bool) throws -> [String: Any] {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw invalid("The project folder must be an absolute local path.") }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw invalid("The project's local folder is unavailable.")
        }
        return try launch(url, open: open)
    }

    private static func launch(_ url: URL, open: (URL) -> Bool) throws -> [String: Any] {
        guard open(url) else { throw invalid("macOS did not accept the open request.") }
        return ["launch_requested": true, "url": url.absoluteString]
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "MicroBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
