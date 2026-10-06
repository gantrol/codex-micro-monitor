import Foundation
import CoreFoundation
import MicroShared

// Desktop preferences determine placement only. Project identity and member
// rows must be read back from the current local App Server before use.
struct PinnedSidebarPreferences:Equatable {
    var projectIDs:[String]=[]
    var aliases:[String:String]=[:]
    var order:[String]=[]
    var manualPins=true
    var manualProjects=false
    var projectOrders:[String:[String]]=[:]
    var needsAllPins:Bool {!projectIDs.isEmpty || !manualPins}
    private static func strings(_ value:Any?,limit:Int=10_000)throws->[String] {
        guard let value,!(value is NSNull) else {return []}
        guard let items=value as? [String],items.count <= limit,items.allSatisfy({!$0.isEmpty && $0.utf8.count <= 4096}) else {
            throw CodexClientError.invalid("Invalid pinned sidebar preferences.")
        }
        var seen:Set<String>=[];return items.filter {seen.insert($0).inserted}
    }
    init() {}
    init(global:[String:Any],root:URL,migrationRoot:String?=nil)throws {
        projectIDs=try Self.strings(global["pinned-project-ids"],limit:1000)
        let atoms: [String:Any]
        if let raw=global["electron-persisted-atom-state"] {
            guard let value=raw as? [String:Any] else {throw CodexClientError.invalid("Invalid sidebar atom state.")};atoms=value
        } else {atoms=[:]}
        order=try Self.strings(atoms["unified-sidebar-pinned-order-v1"])
        if let raw=atoms["pinned-sidebar-sort-mode-v1"],!(raw is NSNull) {
            guard let mode=raw as? String else {throw CodexClientError.invalid("Invalid pinned sort mode.")}
            manualPins=mode == "manual"
        }
        if let raw=atoms["flat-project-sidebar-preferences-v1"],!(raw is NSNull) {
            guard let value=raw as? [String:Any] else {throw CodexClientError.invalid("Invalid project sort mode.")}
            let version=value["manualSortVersion"] as? NSNumber
            manualProjects=value["projectSortMode"] as? String == "manual" && version != nil && CFGetTypeID(version!) != CFBooleanGetTypeID() && version!.intValue == 1 && version!.doubleValue == 1
        }
        if let old=atoms["codex-sidebar-sort-mode-v1"],!(old is NSNull) {manualProjects=false}
        if let raw=global["app-server-project-id-by-legacy-project-id-by-host"] {
            guard let hosts=raw as? [String:Any] else {throw CodexClientError.invalid("Invalid project identity map.")}
            if let raw=hosts["local:"+(migrationRoot ?? root.path)] {
                guard let map=raw as? [String:String],map.count <= 10_000,
                      map.allSatisfy({!$0.key.isEmpty && UUID(uuidString:$0.value) != nil}),
                      Set(map.values).count == map.count else {throw CodexClientError.invalid("Ambiguous project identity map.")}
                aliases=map
            }
        }
        if let raw=global["sidebar-project-thread-orders"] {
            guard let orders=raw as? [String:Any],orders.count <= 10_000 else {throw CodexClientError.invalid("Invalid project member order.")}
            for (id,raw) in orders {
                guard let value=raw as? [String:Any],value["threadIds"] != nil else {continue}
                projectOrders[id]=try Self.strings(value["threadIds"])
            }
        }
    }
    static func load(root:URL,migrationRoot:String?=nil)throws->Self {
        let file=root.appendingPathComponent(".codex-global-state.json")
        guard !file.path.localizedCaseInsensitiveContains("trash") else {throw CodexClientError.invalid("Unsupported sidebar storage path.")}
        guard FileManager.default.fileExists(atPath:file.path) else {return .init()}
        return try .init(global:JSON.object(CodexStorage.read(file,limit:16*1024*1024)),root:root,migrationRoot:migrationRoot)
    }
}

enum PinnedSidebar {
    struct Result {var rows:[[String:Any]];var projectOrders:[String:[String]]}
    private static func threadKey(_ id:String)->String {"codex:thread:local:"+id}
    private static func projectKey(_ id:String)->String {"codex:project:"+id}
    private static func recency(_ rows:[[String:Any]])->[[String:Any]] {
        rows.enumerated().sorted {
            let a=TaskAttention.recency($0.element),b=TaskAttention.recency($1.element)
            return a == b ? $0.offset < $1.offset:a > b
        }.map(\.element)
    }
    private static func pages(_ method:String,_ initial:[String:Any],call:(String,[String:Any])throws->[String:Any])throws->[[String:Any]] {
        var params=initial,rows:[[String:Any]]=[],cursors:Set<String>=[],ids:Set<String>=[]
        for _ in 0..<100 {
            let page=try call(method,params)
            guard let data=page["data"] as? [[String:Any]],data.count <= 100 else {throw CodexClientError.invalid("Invalid pinned project page.")}
            for row in data {
                guard let id=row["id"] as? String,UUID(uuidString:id) != nil,ids.insert(id).inserted else {throw CodexClientError.staleTarget}
                rows.append(row)
            }
            guard let raw=page["nextCursor"],!(raw is NSNull) else {return rows}
            guard let cursor=raw as? String,!cursor.isEmpty,cursors.insert(cursor).inserted,rows.count < 10_000 else {throw CodexClientError.invalid("Incomplete pinned project page.")}
            params["cursor"]=cursor
        }
        throw CodexClientError.invalid("Incomplete pinned project catalog.")
    }
    static func combine(pins:[[String:Any]],preferences: PinnedSidebarPreferences,previousOrders:[String:[String]]=[:],
                        call:(String,[String:Any])throws->[String:Any])throws->Result {
        let pins=preferences.manualPins ? pins:recency(pins)
        let pinIDs=Set(pins.compactMap {$0["id"] as? String})
        var entries=pins.map {threadKey($0["id"] as! String)}
        var groups=Dictionary(uniqueKeysWithValues:zip(entries,pins.map {[$0]})),orders:[String:[String]]=[:]
        if !preferences.projectIDs.isEmpty {
            let projects=try pages("project/list",["limit":100,"sortKey":"position"],call:call)
            let byID=Dictionary(uniqueKeysWithValues:projects.map {($0["id"] as! String,$0)})
            var seenProjects:Set<String>=[],memberIDs:Set<String>=[],total=0
            for legacy in preferences.projectIDs {
                let id=preferences.aliases[legacy] ?? legacy
                guard let project=byID[id],seenProjects.insert(id).inserted else {continue}
                // The Codex sidebar excludes native ChatGPT project mirrors.
                if let roots=project["roots"] as? [[String:Any]],roots.count == 1,
                   let path=roots.first?["path"] as? String,URL(fileURLWithPath:path).deletingLastPathComponent().lastPathComponent == ".chatgpt-projects" {continue}
                let members=try pages("thread/list",["limit":100,"modelProviders":[],"projectId":id,
                    "sortKey":"recency_at","sortDirection":"desc","useStateDbOnly":true,"archived":false],call:call)
                total += members.count
                guard total <= 10_000 else {throw CodexClientError.invalid("Pinned project members exceed the observation limit.")}
                for row in members {
                    guard row["projectId"] as? String == id,memberIDs.insert(row["id"] as! String).inserted else {throw CodexClientError.staleTarget}
                }
                var rows=recency(members.filter {!pinIDs.contains($0["id"] as! String)})
                if preferences.manualProjects {
                    let byID=Dictionary(uniqueKeysWithValues:rows.map {($0["id"] as! String,$0)})
                    let requested=preferences.projectOrders[legacy] ?? previousOrders[legacy] ?? []
                    let manual=requested.filter {byID[$0] != nil},first=Set(manual)
                    rows=manual.compactMap {byID[$0]}+rows.filter {!first.contains($0["id"] as! String)}
                }
                orders[legacy]=rows.map {$0["id"] as! String}
                let key=projectKey(legacy);entries.append(key);groups[key]=rows
            }
        }
        if preferences.manualPins {
            let available=Set(entries),requested=preferences.order.filter {available.contains($0)},first=Set(requested)
            entries=requested+entries.filter {!first.contains($0)}
            // Preserve project positions, but the modern section owns the
            // relative order of local individually pinned chats.
            let local=Set(pins.map {threadKey($0["id"] as! String)});var index=0
            entries=entries.map {key in
                guard local.contains(key) else {return key}
                defer {index += 1};return threadKey(pins[index]["id"] as! String)
            }
        }
        return .init(rows:Array(entries.flatMap {groups[$0] ?? []}.prefix(14)),projectOrders:orders)
    }
}
