import Foundation

// The installed desktop's section engine uses this stable identity, not a
// localized section name. Legacy global pins lack an account/host boundary.
enum PinnedRoster {
    static let sectionID="01984de2-8f74-7c91-a3b2-5c5e937cf318"
    struct Snapshot {
        var rows:[[String:Any]]=[]
        var available=false
        var projectOrders:[String:[String]]=[:]
    }
    private static func next(_ result:[String:Any],seen:inout Set<String>) throws -> String? {
        guard let value=result["nextCursor"],!(value is NSNull) else {return nil}
        guard let cursor=value as? String,!cursor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              seen.insert(cursor).inserted else {throw CodexClientError.invalid("Invalid pinned roster cursor.")}
        return cursor
    }
    static func read(scope:String?,preferences:PinnedSidebarPreferences = .init(),previousOrders:[String:[String]]=[:],
                     call:(String,[String:Any])throws->[String:Any]) throws -> Snapshot {
        guard scope != nil else {return Snapshot()}
        do {
            var cursor:String?,cursors:Set<String>=[],found=false
            for _ in 0..<10 {
                var params:[String:Any]=["limit":100]
                if let cursor {params["cursor"]=cursor}
                let result=try call("threadSection/list",params)
                guard let sections=result["data"] as? [[String:Any]],sections.count <= 100 else {throw CodexClientError.invalid("Missing pinned section catalog.")}
                let matching=sections.filter {$0["id"] as? String == sectionID}
                guard matching.count <= 1 else {throw CodexClientError.invalid("Duplicate pinned section identity.")}
                cursor=try next(result,seen:&cursors)
                if matching.count == 1 {found=true;break}
                if cursor == nil {break}
            }
            guard found else {
                // A complete modern section catalog can prove there are no
                // individual pins while pinned projects still have members.
                guard cursor == nil,!preferences.projectIDs.isEmpty else {return Snapshot()}
                let combined=try PinnedSidebar.combine(pins:[],preferences:preferences,previousOrders:previousOrders,call:call)
                return Snapshot(rows:combined.rows,available:true,projectOrders:combined.projectOrders)
            }
            cursor=nil;cursors=[]
            var rows:[[String:Any]]=[],ids:Set<String>=[]
            for _ in 0..<10 {
                // Omit sortDirection exactly as the desktop section engine does.
                var params:[String:Any]=["limit":100,"modelProviders":[],"sectionId":sectionID,
                    "sortKey":"section_position","useStateDbOnly":true,"archived":false]
                if let cursor {params["cursor"]=cursor}
                let result=try call("thread/list",params)
                guard let page=result["data"] as? [[String:Any]],page.count <= 100 else {throw CodexClientError.invalid("Missing pinned task catalog.")}
                for row in page {
                    guard let id=row["id"] as? String,UUID(uuidString:id) != nil,
                          (row["section"] as? [String:Any])?["id"] as? String == sectionID,
                          ids.insert(id).inserted else {throw CodexClientError.staleTarget}
                    rows.append(row)
                }
                cursor=try next(result,seen:&cursors)
                if cursor == nil || (!preferences.needsAllPins && rows.count >= 14) {
                    let combined=try PinnedSidebar.combine(pins:rows,preferences:preferences,previousOrders:previousOrders,call:call)
                    return Snapshot(rows:combined.rows,available:true,projectOrders:combined.projectOrders)
                }
            }
            // A bounded lookup cannot claim that a partial prefix is complete.
            return Snapshot()
        } catch CodexClientError.rejected {
            // Older servers may not support sections/section_position. Do not
            // substitute a global file, recent tasks or trigger pin migration.
            return Snapshot()
        }
    }
}
