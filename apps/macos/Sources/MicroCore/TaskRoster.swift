import Foundation

enum TaskRoster {
    struct Request {
        let scope:String
        let ids:[String]
    }
    static func request(_ arguments:[String:Any]) throws -> Request? {
        guard arguments["mapped_thread_ids"] != nil else {return nil}
        guard let ids=arguments["mapped_thread_ids"] as? [String],ids.count <= 14,
              ids.allSatisfy({UUID(uuidString:$0) != nil}),
              let scope=arguments["roster_scope"] as? String,scope.count == 64,
              scope.allSatisfy({"0123456789abcdef".contains($0)}) else {
            throw CodexClientError.invalid("Mapped tasks require at most 14 exact IDs and the observed roster scope.")
        }
        var seen:Set<String>=[]
        return Request(scope:scope,ids:ids.filter {seen.insert($0).inserted})
    }
    static func scope(_ context:CodexReadContext?,root:URL) -> String? {
        context.flatMap {CodexStorage.hash(["micro-task-roster-v1",$0.identityKey,$0.executionHostKey,root.path])}
    }
    static func resolve(_ request:Request?,scope:String?,recent:[[String:Any]],
                        read:(String)throws->[String:Any]) throws -> (rows:[[String:Any]],unavailable:[String]) {
        guard let request,let scope,request.scope == scope else {return ([],[])}
        let existing=Dictionary(recent.compactMap {row in (row["id"] as? String).map {($0,row)}},uniquingKeysWith:{first,_ in first})
        var rows:[[String:Any]]=[],unavailable:[String]=[]
        for id in request.ids {
            if let row=existing[id] {rows.append(row);continue}
            do {
                let result=try read(id)
                guard let row=result["thread"] as? [String:Any],row["id"] as? String == id else {throw CodexClientError.staleTarget}
                rows.append(row)
            } catch CodexClientError.rejected {unavailable.append(id)}
        }
        return (rows,unavailable)
    }
}
