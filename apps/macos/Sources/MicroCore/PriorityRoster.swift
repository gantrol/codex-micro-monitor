import Foundation

enum PriorityRoster {
    // A guard against unbounded/malformed peers, not a truncated UI roster.
    // Reaching the bound fails the observation; no partial ranking is returned.
    static let maximumRows=10_000
    static func read(first:[String:Any],call:([String:Any])throws->[String:Any]) throws -> [[String:Any]] {
        var page=first,rows:[[String:Any]]=[],ids:Set<String>=[],cursors:Set<String>=[]
        while true {
            guard let data=page["data"] as? [[String:Any]],data.count <= 100 else {throw CodexClientError.invalid("Invalid priority task page.")}
            for row in data {
                guard let id=row["id"] as? String,UUID(uuidString:id) != nil,ids.insert(id).inserted else {throw CodexClientError.staleTarget}
                rows.append(row)
            }
            guard let raw=page["nextCursor"],!(raw is NSNull) else {return rows}
            guard let cursor=raw as? String,!cursor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  cursors.insert(cursor).inserted,rows.count < maximumRows,cursors.count <= 100 else {
                throw CodexClientError.invalid("Incomplete priority task catalog.")
            }
            page=try call(["limit":100,"sortKey":"recency_at","sortDirection":"desc","useStateDbOnly":true,"cursor":cursor])
        }
    }
}
