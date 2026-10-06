import Foundation
import MicroShared

/// Persisted renderer identities are evidence for a read, never a control lease.
enum ClientThreadBinding {
    struct Evidence:Equatable {
        let threadID:String?
        let sources:Set<String>
    }
    static func evidence(_ state:[String:Any],client:String)throws->Evidence {
        guard ClientThreadIdentity.canonical(client) == client else {throw CodexClientError.invalid("Expected an exact client thread identity.")}
        guard state["electron-persisted-atom-state"] != nil else {return Evidence(threadID:nil,sources:[])}
        guard let atoms=state["electron-persisted-atom-state"] as? [String:Any] else {throw CodexClientError.invalid("Invalid persisted thread identities.")}
        var ids:Set<String>=[],sources:Set<String>=[]
        func add(_ value:Any,source:String)throws {
            guard let value=value as? String,value.count == 36,let id=UUID(uuidString:value) else {throw CodexClientError.invalid("Invalid client thread binding.")}
            ids.insert(id.uuidString.lowercased());sources.insert(source)
        }
        if let raw=atoms["client-thread-bindings-v1"] {
            guard let bindings=raw as? [String:Any],bindings.count <= 1000 else {throw CodexClientError.invalid("Invalid client thread binding catalog.")}
            for (key,value) in bindings where ClientThreadIdentity.canonical(key) == client {try add(value,source:"forward:"+key)}
        }
        let prefix="thread-client-id-v1:"
        for (key,value) in atoms where key.hasPrefix(prefix) {
            guard let value=value as? String,ClientThreadIdentity.canonical(value) == client,
                  let decoded=String(key.dropFirst(prefix.count)).removingPercentEncoding,decoded.hasPrefix("local:") else {continue}
            try add(String(decoded.dropFirst(6)),source:"reverse:"+key)
        }
        guard ids.count <= 1 else {throw CodexClientError.staleTarget}
        return Evidence(threadID:ids.first,sources:sources)
    }
    static func load(root:URL,client:String)throws->Evidence {
        let data=try CodexStorage.read(root.appendingPathComponent(".codex-global-state.json"),limit:16*1024*1024)
        guard let state=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw CodexClientError.invalid("Invalid persisted thread identities.")}
        return try evidence(state,client:client)
    }
}
