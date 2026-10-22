import CryptoKit
import Foundation
import Security

struct ClientDeviceIdentity: Codable, Equatable, Sendable {
    var deviceID: String
    var deviceName: String
    var privateKeyBase64: String
    var publicKeyBase64: String
}

struct SavedHost: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var platform: MicroRemotePlatform
    var mode: MicroRemoteConnectionMode
    var endpoints: [String]
    var relayURL: String?
    var token: String
    var isPairingToken: Bool
    var certificateSHA256: String
    var hostPublicKey: String?
    var lastConnectedAtMs: Int64

    var primaryEndpoint: String {
        if mode == .relayE2EE, let relayURL, !relayURL.isEmpty {
            return relayURL
        }
        return endpoints.first ?? ""
    }

    var normalizedPin: String {
        certificateSHA256
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    func validatedCandidateURLs() throws -> [URL] {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty,
              trimmedToken.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MicroError.message("请输入有效的配对码或设备令牌")
        }

        if mode == .relayE2EE {
            guard let relayURL, let url = URL(string: relayURL),
                  ["wss", "ws"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else {
                throw MicroError.message("请输入有效的中继 WSS 地址")
            }
            return [url]
        }

        let urls = endpoints.compactMap { raw -> URL? in
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let u = URL(string: s),
                  ["wss", "ws"].contains(u.scheme?.lowercased() ?? ""),
                  u.host != nil, u.user == nil, u.password == nil else {
                return nil
            }
            return u
        }
        guard !urls.isEmpty else {
            throw MicroError.message("请输入有效的 WSS 连接地址")
        }

        let pin = normalizedPin
        guard pin.isEmpty || (pin.count == 64 && pin.allSatisfy({ $0.isHexDigit })) else {
            throw MicroError.message("证书指纹须为 64 位 SHA-256")
        }
        return urls
    }

    static func fromPairPayload(_ payload: MicroRemotePairPayload) -> SavedHost {
        SavedHost(
            id: payload.hostID,
            name: payload.hostName,
            platform: payload.platform,
            mode: payload.mode,
            endpoints: payload.endpoints,
            relayURL: payload.relayURL,
            token: payload.pairingToken,
            isPairingToken: true,
            certificateSHA256: payload.certPinSHA256 ?? "",
            hostPublicKey: payload.hostPublicKey,
            lastConnectedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}

typealias HostCredentials = SavedHost

enum HostKeychain {
    private static let service = "CodexMicro.iOS.host"
    private static let hostsAccount = "hosts_v2"
    private static let identityAccount = "device_identity_v2"
    private static let legacyAccount = "host"
    private static let activeHostDefaultsKey = "micro.activeHostID"

    private struct LegacyHostCredentials: Codable {
        var endpoint: String
        var token: String
        var certificateSHA256: String
    }

    static func deviceIdentity(defaultDeviceName: String = "iPhone") -> ClientDeviceIdentity {
        if let data = readKeychainData(account: identityAccount),
           let decoded = try? JSONDecoder().decode(ClientDeviceIdentity.self, from: data) {
            return decoded
        }
        let pair = MicroRemoteCrypto.generateKeyPair()
        let identity = ClientDeviceIdentity(
            deviceID: "ios-" + UUID().uuidString.lowercased().prefix(12),
            deviceName: defaultDeviceName,
            privateKeyBase64: pair.privateKeyBase64,
            publicKeyBase64: pair.publicKeyBase64
        )
        if let data = try? JSONEncoder().encode(identity) {
            try? writeKeychainData(data, account: identityAccount)
        }
        return identity
    }

    static func loadHosts() -> [SavedHost] {
        if let data = readKeychainData(account: hostsAccount),
           let hosts = try? JSONDecoder().decode([SavedHost].self, from: data) {
            return hosts
        }
        if let legacyData = readKeychainData(account: legacyAccount),
           let legacy = try? JSONDecoder().decode(LegacyHostCredentials.self, from: legacyData),
           !legacy.endpoint.isEmpty {
            let hostTitle = URL(string: legacy.endpoint)?.host ?? "Host"
            let migrated = SavedHost(
                id: "host-" + MicroRemoteCrypto.sha256Hex(legacy.endpoint).prefix(10),
                name: hostTitle,
                platform: .unknown,
                mode: .directTailscale,
                endpoints: [legacy.endpoint],
                relayURL: nil,
                token: legacy.token,
                isPairingToken: false,
                certificateSHA256: legacy.certificateSHA256,
                hostPublicKey: nil,
                lastConnectedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
            try? saveHosts([migrated])
            return [migrated]
        }
        return []
    }

    static func saveHosts(_ hosts: [SavedHost]) throws {
        let data = try JSONEncoder().encode(hosts)
        try writeKeychainData(data, account: hostsAccount)
    }

    static func upsertHost(_ host: SavedHost) throws {
        var all = loadHosts()
        if let idx = all.firstIndex(where: { $0.id == host.id }) {
            all[idx] = host
        } else {
            all.insert(host, at: 0)
        }
        try saveHosts(all)
        setActiveHostID(host.id)
    }

    static func removeHost(id: String) throws {
        var all = loadHosts()
        all.removeAll { $0.id == id }
        try saveHosts(all)
        if activeHostID() == id {
            setActiveHostID(all.first?.id)
        }
    }

    static func activeHostID() -> String? {
        UserDefaults.standard.string(forKey: activeHostDefaultsKey)
    }

    static func setActiveHostID(_ id: String?) {
        UserDefaults.standard.set(id, forKey: activeHostDefaultsKey)
    }

    static func activeHost() -> SavedHost? {
        let all = loadHosts()
        if let activeID = activeHostID(),
           let matched = all.first(where: { $0.id == activeID }) {
            return matched
        }
        return all.first
    }

    private static func readKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func writeKeychainData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            let entry = query.merging(changes) { _, new in new }
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else {
                throw MicroError.message("无法保存设备凭据")
            }
        } else if status != errSecSuccess {
            throw MicroError.message("无法更新设备凭据")
        }
    }
}

final class HostTrustDelegate: NSObject, URLSessionTaskDelegate {
    private let host: String
    private let pin: String

    init(host: String, pin: String) {
        self.host = host
        self.pin = pin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard !pin.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == pin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
