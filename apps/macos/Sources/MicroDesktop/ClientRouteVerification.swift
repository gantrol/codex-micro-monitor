import Foundation
import MicroShared

// Internal receipt minted only after Core checks the exact local binding.
// Neither the receipt nor a way to supply one is exposed over MCP/XPC.
struct VerifiedClientRoute:Equatable {
    let pair:ClientRoutePair
    let scope:String
    let context:String
    let nonce=UUID()
    let issuedAt=ProcessInfo.processInfo.systemUptime
    var fresh:Bool {let age=ProcessInfo.processInfo.systemUptime-issuedAt;return age >= 0 && age < 5}
    func sameIdentity(_ other:VerifiedClientRoute?)->Bool {
        other?.pair == pair && other?.scope == scope && other?.context == context
    }
}
