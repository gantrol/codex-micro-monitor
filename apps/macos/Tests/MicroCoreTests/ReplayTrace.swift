import Foundation

enum ReplayTrace {
    static func emit(_ prefix:String,_ value:[String:Any]) {
        let json=try! JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
        var line=Data((prefix+" ").utf8);line.append(json);line.append(10)
        // One unbuffered record avoids stdout/stderr interleaving when XCTest
        // diagnostics and replay evidence share the redirected build log.
        FileHandle.standardError.write(line)
    }
}
