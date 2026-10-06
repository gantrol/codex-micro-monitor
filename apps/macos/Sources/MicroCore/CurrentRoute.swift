import Foundation
import MicroShared

/// A live document route can also prove that the window has left a chat.
/// Bootstrap initialRoute, embedded websites and titles are not live identity.
public struct CurrentRoute: Equatable {
    public let threadID: String?
    public let draft: Bool
    public let known: Bool
    public let key: String?
    public let pendingBinding:ClientRoutePair?
    private init(threadID:String?,draft:Bool,known:Bool,key:String?,pendingBinding:ClientRoutePair?=nil) {
        self.threadID=threadID;self.draft=draft;self.known=known;self.key=key;self.pendingBinding=pendingBinding
    }

    // A client identity can survive conversation creation. It identifies the
    // native composer, but is not proof of a server UUID or an unsent draft.
    public var clientThreadID: String? { Self.clientThreadID(routeKey:key) }
    public static func clientThreadID(routeKey:String?) -> String? {
        ClientThreadIdentity.fromRoute(routeKey)
    }

    public func allowsNativeComposer(selectedSidebarCount: Int) -> Bool {
        !known && threadID == nil && !draft && selectedSidebarCount == 1
    }

    public static func resolve(documents: [String], selectedLinks: [String], homeComposer: Bool, composerAvailable:Bool=false) -> CurrentRoute {
        let routes = Set(documents.compactMap(documentLocation))
        if routes.count > 1 { return .init(threadID: nil, draft: false, known: true, key: "conflict") }
        let selected = Set(selectedLinks.compactMap(sidebarLocation))
        if let location = routes.first {
            switch location {
            case .thread(let id):
                if !homeComposer,selectedLinks.count == 1,selected.count == 1,case .client(let client)?=selected.first,
                   let pair=ClientRoutePair(clientThreadID:client,threadID:id,documentIsClient:false) {
                    return .init(threadID:nil,draft:false,known:true,key:pair.routeKey,pendingBinding:pair)
                }
                guard !homeComposer, selected.isEmpty || selected == [location] else {
                    return .init(threadID: nil, draft: false, known: true, key: "conflict")
                }
                return .init(threadID: id, draft: false, known: true, key: "thread:" + id)
            case .client(let id):
                if !homeComposer,selectedLinks.count == 1,selected.count == 1,case .thread(let thread)?=selected.first,
                   let pair=ClientRoutePair(clientThreadID:id,threadID:thread,documentIsClient:true) {
                    return .init(threadID:nil,draft:false,known:true,key:pair.routeKey,pendingBinding:pair)
                }
                guard selected.isEmpty || selected == [location] else {
                    return .init(threadID:nil,draft:false,known:true,key:"conflict")
                }
                return .init(threadID:nil,draft:false,known:true,key:"client:"+id)
            case .page(let path):
                return .init(threadID: nil, draft: false, known: true, key: "page:" + path)
            case .draftPage(let path,let key,let needsHome):
                let draft=needsHome ? homeComposer:composerAvailable
                return .init(threadID:nil,draft:draft,known:true,key:draft ? key:"page:"+path)
            case .foreign(let path,let host):
                return .init(threadID:nil,draft:false,known:true,key:"host:"+host+":"+path)
            }
        }
        if homeComposer { return .init(threadID: nil, draft: true, known: true, key: "draft") }
        if selected.count == 1, let location=selected.first {
            switch location {
            case .thread(let id):return .init(threadID:id,draft:false,known:true,key:"thread:"+id)
            case .client(let id):return .init(threadID:nil,draft:false,known:true,key:"client:"+id)
            case .foreign(let path,let host):return .init(threadID:nil,draft:false,known:true,key:"host:"+host+":"+path)
            case .page,.draftPage:break
            }
        }
        return .init(threadID: nil, draft: false, known: !selected.isEmpty, key: selected.isEmpty ? nil : "conflict")
    }

    public static func documentPath(_ value: String) -> String? {
        guard let url = URLComponents(string: value), url.scheme == "app", url.host == "-",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        guard !["/index.html", "/detached-window.html"].contains(path) else { return nil }
        return path
    }

    public static func sidebarThread(_ value: String) -> String? {
        if case .thread(let id)=sidebarLocation(value) {return id}
        return nil
    }

    private enum Location:Hashable {case thread(String),client(String),page(String),draftPage(String,String,Bool),foreign(String,String)}
    private static func documentLocation(_ value:String)->Location? {
        guard documentPath(value) != nil,let url=URLComponents(string:value) else {return nil}
        return location(url)
    }
    private static func sidebarLocation(_ value:String)->Location? {
        if value.hasPrefix("/"), !value.hasPrefix("//"), let url = URLComponents(string: value) {
            return location(url)
        }
        guard let url = URLComponents(string: value) else { return nil }
        if documentPath(value) != nil { return location(url) }
        if url.scheme == "codex", url.host == "threads", url.user == nil, url.password == nil, url.port == nil {
            return location(url,deepLink:true)
        }
        return nil
    }
    private static func location(_ url:URLComponents,deepLink:Bool=false)->Location {
        let path=url.path.isEmpty ? "/":url.path
        let hosts=(url.queryItems ?? []).filter {$0.name == "hostId"}
        guard hosts.isEmpty || hosts.count == 1 && hosts[0].value == "local" else {
            return .foreign(path,hosts.count == 1 ? hosts[0].value ?? "invalid":"ambiguous")
        }
        if !deepLink {
            if path == "/" {return .draftPage(path,"draft",true)}
            // Hotkey composers use their own shell/footer, not the main home's
            // container class. Still require a visible unique native composer.
            if ["/hotkey-window","/hotkey-window/new-thread"].contains(path) {return .draftPage(path,"draft:"+path,false)}
            if path == "/projects" {
                let projects=(url.queryItems ?? []).filter {$0.name == "projectId"}
                if projects.count == 1,let project=projects[0].value,!project.isEmpty,project.utf8.count <= 256,
                   !project.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) {
                    let encoded=project.addingPercentEncoding(withAllowedCharacters:CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~")))!
                    return .draftPage(path,"draft:/projects?projectId="+encoded,true)
                }
            }
        }
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        let value:String?
        if deepLink,parts.count == 2,parts[0].isEmpty {value=String(parts[1])}
        else if parts.count == 3,parts[0].isEmpty,parts[1] == "local" {value=String(parts[2])}
        else if parts.count == 4,parts[0].isEmpty,parts[1] == "hotkey-window",parts[2] == "thread" {value=String(parts[3])}
        else {value=nil}
        if let value,let id=canonicalID(value) {return .thread(id)}
        if !deepLink,let value,let id=ClientThreadIdentity.canonical(value) {return .client(id)}
        return .page(path)
    }

    private static func canonicalID(_ value: String) -> String? {
        guard value.count == 36, let id = UUID(uuidString: value) else { return nil }
        return id.uuidString.lowercased()
    }
}
