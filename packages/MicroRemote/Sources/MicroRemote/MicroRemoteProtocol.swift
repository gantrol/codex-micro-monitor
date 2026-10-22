import CryptoKit
import Foundation

public enum MicroRemoteConstants {
    public static let protocolVersion = 2
    public static let minSupportedVersion = 1
    public static let defaultPort: UInt16 = 48720
    public static let defaultWebSocketPath = "/ws/micro"
    public static let relayInfoString = "codex-micro-relay-v2"
}

public enum MicroRemoteConnectionMode: String, Codable, Sendable, CaseIterable {
    case directTailscale = "direct"
    case relayE2EE = "relay"
}

public enum MicroRemotePlatform: String, Codable, Sendable {
    case macos
    case windows
    case ios
    case unknown
}

public enum MicroRemoteRole: String, Codable, Sendable {
    case readWrite
    case readOnly
}

public enum MicroRemoteCommandOutcomeStatus: String, Codable, Sendable {
    case completed
    case inProgress = "in_progress"
    case rejected
    case unknown
}

public enum MicroRemoteApprovalKind: String, Codable, Sendable {
    case command
    case fileChange
    case other
}

public struct MicroRemotePairPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var mode: MicroRemoteConnectionMode
    public var hostID: String
    public var hostName: String
    public var platform: MicroRemotePlatform
    public var endpoints: [String]
    public var relayURL: String?
    public var certPinSHA256: String?
    public var hostPublicKey: String?
    public var pairingToken: String
    public var expiresAtMs: Int64

    public init(
        version: Int = MicroRemoteConstants.protocolVersion,
        mode: MicroRemoteConnectionMode,
        hostID: String,
        hostName: String,
        platform: MicroRemotePlatform,
        endpoints: [String],
        relayURL: String? = nil,
        certPinSHA256: String? = nil,
        hostPublicKey: String? = nil,
        pairingToken: String,
        expiresAtMs: Int64
    ) {
        self.version = version
        self.mode = mode
        self.hostID = hostID
        self.hostName = hostName
        self.platform = platform
        self.endpoints = endpoints
        self.relayURL = relayURL
        self.certPinSHA256 = certPinSHA256
        self.hostPublicKey = hostPublicKey
        self.pairingToken = pairingToken
        self.expiresAtMs = expiresAtMs
    }

    public func toURIString() -> String {
        var components = URLComponents()
        components.scheme = "codexmicro"
        components.host = "pair"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "hostId", value: hostID),
            URLQueryItem(name: "name", value: hostName),
            URLQueryItem(name: "platform", value: platform.rawValue),
            URLQueryItem(name: "token", value: pairingToken),
            URLQueryItem(name: "exp", value: String(expiresAtMs)),
        ]
        for ep in endpoints where !ep.isEmpty {
            items.append(URLQueryItem(name: "ep", value: ep))
        }
        if let relayURL, !relayURL.isEmpty {
            items.append(URLQueryItem(name: "relay", value: relayURL))
        }
        if let certPinSHA256, !certPinSHA256.isEmpty {
            items.append(URLQueryItem(name: "pin", value: certPinSHA256))
        }
        if let hostPublicKey, !hostPublicKey.isEmpty {
            items.append(URLQueryItem(name: "pub", value: hostPublicKey))
        }
        components.queryItems = items
        return components.string ?? ""
    }

    public static func parse(_ raw: String) -> MicroRemotePairPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(MicroRemotePairPayload.self, from: data) {
            return decoded
        }

        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "codexmicro" else {
            return nil
        }

        let items = components.queryItems ?? []
        func firstValue(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        let endpoints = items.filter { $0.name == "ep" }.compactMap { $0.value }.filter { !$0.isEmpty }
        guard let hostID = firstValue("hostId"), !hostID.isEmpty,
              let token = firstValue("token"), !token.isEmpty else {
            return nil
        }
        let version = Int(firstValue("v") ?? "2") ?? 2
        let mode = MicroRemoteConnectionMode(rawValue: firstValue("mode") ?? "direct") ?? .directTailscale
        let hostName = firstValue("name") ?? hostID
        let platform = MicroRemotePlatform(rawValue: firstValue("platform") ?? "unknown") ?? .unknown
        let exp = Int64(firstValue("exp") ?? "0") ?? 0

        return MicroRemotePairPayload(
            version: version,
            mode: mode,
            hostID: hostID,
            hostName: hostName,
            platform: platform,
            endpoints: endpoints,
            relayURL: firstValue("relay"),
            certPinSHA256: firstValue("pin"),
            hostPublicKey: firstValue("pub"),
            pairingToken: token,
            expiresAtMs: exp
        )
    }
}

public struct MicroRelayEnvelope: Codable, Equatable, Sendable {
    public var type: String
    public var v: Int
    public var sessionID: String
    public var hostID: String
    public var deviceID: String
    public var senderPublicKey: String
    public var seq: UInt64
    public var nonce: String
    public var ciphertext: String

    public init(
        v: Int = MicroRemoteConstants.protocolVersion,
        sessionID: String,
        hostID: String,
        deviceID: String,
        senderPublicKey: String,
        seq: UInt64,
        nonce: String,
        ciphertext: String
    ) {
        self.type = "relay.envelope"
        self.v = v
        self.sessionID = sessionID
        self.hostID = hostID
        self.deviceID = deviceID
        self.senderPublicKey = senderPublicKey
        self.seq = seq
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

public enum MicroRemoteCrypto {
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    public static func computeApprovalContentHash(
        requestID: String,
        kind: MicroRemoteApprovalKind,
        commandText: String?,
        cwd: String?,
        filePaths: [String]
    ) -> String {
        let joinedPaths = filePaths.sorted().joined(separator: "\n")
        let canonical = [
            requestID,
            kind.rawValue,
            commandText ?? "",
            cwd ?? "",
            joinedPaths,
        ].joined(separator: "|")
        return sha256Hex(canonical)
    }

    public static func computeCommandPayloadHash(type: String, fields: [(String, String)]) -> String {
        let sorted = fields.sorted { $0.0 < $1.0 }
        var parts: [String] = [type]
        for (key, value) in sorted {
            parts.append("\(key)=\(value)")
        }
        return sha256Hex(parts.joined(separator: "&"))
    }

    public static func generateKeyPair() -> (privateKeyBase64: String, publicKeyBase64: String) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return (
            privateKey.rawRepresentation.base64EncodedString(),
            privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    public static func publicKeyBase64(fromPrivateKeyBase64 privateKeyBase64: String) -> String? {
        guard let raw = Data(base64Encoded: privateKeyBase64),
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            return nil
        }
        return privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    public static func sealRelayEnvelope(
        plaintext: Data,
        sessionID: String,
        hostID: String,
        deviceID: String,
        seq: UInt64,
        senderPrivateKeyBase64: String,
        recipientPublicKeyBase64: String
    ) throws -> MicroRelayEnvelope {
        let key = try deriveSymmetricKey(
            privateKeyBase64: senderPrivateKeyBase64,
            peerPublicKeyBase64: recipientPublicKeyBase64,
            hostID: hostID,
            deviceID: deviceID
        )
        guard let senderPublicKey = publicKeyBase64(fromPrivateKeyBase64: senderPrivateKeyBase64) else {
            throw MicroRemoteCryptoError.invalidKey
        }
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        let seqBigEndian = seq.bigEndian
        withUnsafeBytes(of: seqBigEndian) { ptr in
            for idx in 0..<min(8, ptr.count) {
                nonceBytes[4 + idx] = ptr[idx]
            }
        }
        let randomPrefix = SymmetricKey(size: .bits128)
        randomPrefix.withUnsafeBytes { ptr in
            for idx in 0..<min(4, ptr.count) {
                nonceBytes[idx] = ptr[idx]
            }
        }
        let nonce = try ChaChaPoly.Nonce(data: Data(nonceBytes))
        let aad = Data("\(sessionID)|\(hostID)|\(deviceID)|\(seq)".utf8)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var combinedCiphertext = Data(sealed.ciphertext)
        combinedCiphertext.append(sealed.tag)

        return MicroRelayEnvelope(
            sessionID: sessionID,
            hostID: hostID,
            deviceID: deviceID,
            senderPublicKey: senderPublicKey,
            seq: seq,
            nonce: Data(nonceBytes).base64EncodedString(),
            ciphertext: combinedCiphertext.base64EncodedString()
        )
    }

    public static func openRelayEnvelope(
        _ envelope: MicroRelayEnvelope,
        recipientPrivateKeyBase64: String
    ) throws -> Data {
        let key = try deriveSymmetricKey(
            privateKeyBase64: recipientPrivateKeyBase64,
            peerPublicKeyBase64: envelope.senderPublicKey,
            hostID: envelope.hostID,
            deviceID: envelope.deviceID
        )
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let combinedData = Data(base64Encoded: envelope.ciphertext),
              combinedData.count >= 16 else {
            throw MicroRemoteCryptoError.invalidCiphertext
        }
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let ciphertext = combinedData.prefix(combinedData.count - 16)
        let tag = combinedData.suffix(16)
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let aad = Data("\(envelope.sessionID)|\(envelope.hostID)|\(envelope.deviceID)|\(envelope.seq)".utf8)
        return try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
    }

    private static func deriveSymmetricKey(
        privateKeyBase64: String,
        peerPublicKeyBase64: String,
        hostID: String,
        deviceID: String
    ) throws -> SymmetricKey {
        guard let privData = Data(base64Encoded: privateKeyBase64),
              let pubData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw MicroRemoteCryptoError.invalidKey
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privData)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let salt = Data("\(hostID)|\(deviceID)".utf8)
        let info = Data(MicroRemoteConstants.relayInfoString.utf8)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
    }
}

public enum MicroRemoteCryptoError: Error, Sendable {
    case invalidKey
    case invalidCiphertext
}

// MARK: - Protocol v2 DTOs

public struct MicroRemotePendingApprovalDTO: Codable, Equatable, Sendable {
    public var id: String
    public var kind: MicroRemoteApprovalKind
    public var summary: String
    public var commandText: String?
    public var cwd: String?
    public var filePaths: [String]
    public var approvalContentHash: String
    public var createdAtMs: Int64

    public init(
        id: String,
        kind: MicroRemoteApprovalKind = .other,
        summary: String,
        commandText: String? = nil,
        cwd: String? = nil,
        filePaths: [String] = [],
        approvalContentHash: String? = nil,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.commandText = commandText
        self.cwd = cwd
        self.filePaths = filePaths
        self.approvalContentHash = approvalContentHash ?? MicroRemoteCrypto.computeApprovalContentHash(
            requestID: id,
            kind: kind,
            commandText: commandText,
            cwd: cwd,
            filePaths: filePaths
        )
        self.createdAtMs = createdAtMs
    }
}

public struct MicroRemotePendingQuestionDTO: Codable, Equatable, Sendable {
    public var id: String
    public var prompt: String
    public var options: [String]

    public init(id: String, prompt: String, options: [String] = []) {
        self.id = id
        self.prompt = prompt
        self.options = options
    }
}

public struct MicroRemoteLatestReplyDTO: Codable, Equatable, Sendable {
    public var turnID: String?
    public var text: String
    public var updatedAtMs: Int64
    public var isStreaming: Bool

    public init(turnID: String? = nil, text: String, updatedAtMs: Int64, isStreaming: Bool = false) {
        self.turnID = turnID
        self.text = text
        self.updatedAtMs = updatedAtMs
        self.isStreaming = isStreaming
    }
}

public struct MicroRemoteThreadDTO: Codable, Equatable, Sendable {
    public var id: String
    public var slotIndex: Int?
    public var title: String
    public var workspaceName: String
    public var status: String
    public var activeTurnID: String?
    public var hasDraft: Bool
    public var hasUnreadCompletion: Bool
    public var pendingApprovalCount: Int
    public var pendingQuestionCount: Int
    public var updatedAtMs: Int64
    public var model: String?
    public var effort: String?
    public var fastMode: Bool?
    public var planMode: Bool?
    public var pendingApproval: MicroRemotePendingApprovalDTO?

    public init(
        id: String,
        slotIndex: Int? = nil,
        title: String,
        workspaceName: String,
        status: String,
        activeTurnID: String? = nil,
        hasDraft: Bool = false,
        hasUnreadCompletion: Bool = false,
        pendingApprovalCount: Int = 0,
        pendingQuestionCount: Int = 0,
        updatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        model: String? = nil,
        effort: String? = nil,
        fastMode: Bool? = nil,
        planMode: Bool? = nil,
        pendingApproval: MicroRemotePendingApprovalDTO? = nil
    ) {
        self.id = id
        self.slotIndex = slotIndex
        self.title = title
        self.workspaceName = workspaceName
        self.status = status
        self.activeTurnID = activeTurnID
        self.hasDraft = hasDraft
        self.hasUnreadCompletion = hasUnreadCompletion
        self.pendingApprovalCount = pendingApprovalCount
        self.pendingQuestionCount = pendingQuestionCount
        self.updatedAtMs = updatedAtMs
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.planMode = planMode
        self.pendingApproval = pendingApproval
    }
}

public struct MicroRemoteQuotaWindowDTO: Codable, Equatable, Sendable {
    public var remainingRatio: Double?
    public var resetProgressRatio: Double?
    public var resetAtMs: Int64?

    public init(remainingRatio: Double?, resetProgressRatio: Double?, resetAtMs: Int64? = nil) {
        self.remainingRatio = remainingRatio
        self.resetProgressRatio = resetProgressRatio
        self.resetAtMs = resetAtMs
    }
}

public struct MicroRemoteQuotaDTO: Codable, Equatable, Sendable {
    public var fiveHour: MicroRemoteQuotaWindowDTO
    public var sevenDay: MicroRemoteQuotaWindowDTO
    public var updatedAtMs: Int64?

    public init(
        fiveHour: MicroRemoteQuotaWindowDTO,
        sevenDay: MicroRemoteQuotaWindowDTO,
        updatedAtMs: Int64? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAtMs = updatedAtMs
    }
}

public struct MicroRemoteModelCatalogDTO: Codable, Equatable, Sendable {
    public var models: [String]
    public var effortsByModel: [String: [String]]

    public init(models: [String], effortsByModel: [String: [String]]) {
        self.models = models
        self.effortsByModel = effortsByModel
    }
}

public struct MicroRemoteSnapshotPayload: Codable, Equatable, Sendable {
    public var revision: Int
    public var hostID: String?
    public var hostName: String
    public var hostPlatform: MicroRemotePlatform?
    public var snapshotUpdatedAtMs: Int64?
    public var keypadSlotCount: Int
    public var selectedThreadID: String?
    public var model: String?
    public var effort: String?
    public var fastMode: Bool?
    public var planMode: Bool?
    public var modelCatalog: MicroRemoteModelCatalogDTO?
    public var quota: MicroRemoteQuotaDTO
    public var threads: [MicroRemoteThreadDTO]
    public var totalThreadCount: Int?

    public init(
        revision: Int,
        hostID: String? = nil,
        hostName: String,
        hostPlatform: MicroRemotePlatform? = nil,
        snapshotUpdatedAtMs: Int64? = Int64(Date().timeIntervalSince1970 * 1000),
        keypadSlotCount: Int,
        selectedThreadID: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        fastMode: Bool? = nil,
        planMode: Bool? = nil,
        modelCatalog: MicroRemoteModelCatalogDTO? = nil,
        quota: MicroRemoteQuotaDTO,
        threads: [MicroRemoteThreadDTO],
        totalThreadCount: Int? = nil
    ) {
        self.revision = revision
        self.hostID = hostID
        self.hostName = hostName
        self.hostPlatform = hostPlatform
        self.snapshotUpdatedAtMs = snapshotUpdatedAtMs
        self.keypadSlotCount = keypadSlotCount
        self.selectedThreadID = selectedThreadID
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.planMode = planMode
        self.modelCatalog = modelCatalog
        self.quota = quota
        self.threads = threads
        self.totalThreadCount = totalThreadCount
    }
}

public struct MicroRemoteThreadDetailResultPayload: Codable, Equatable, Sendable {
    public var threadID: String
    public var revision: Int
    public var activeTurnID: String?
    public var status: String
    public var canSubmitText: Bool
    public var latestReply: MicroRemoteLatestReplyDTO?
    public var approvals: [MicroRemotePendingApprovalDTO]
    public var pendingQuestions: [MicroRemotePendingQuestionDTO]

    public init(
        threadID: String,
        revision: Int,
        activeTurnID: String? = nil,
        status: String,
        canSubmitText: Bool,
        latestReply: MicroRemoteLatestReplyDTO? = nil,
        approvals: [MicroRemotePendingApprovalDTO] = [],
        pendingQuestions: [MicroRemotePendingQuestionDTO] = []
    ) {
        self.threadID = threadID
        self.revision = revision
        self.activeTurnID = activeTurnID
        self.status = status
        self.canSubmitText = canSubmitText
        self.latestReply = latestReply
        self.approvals = approvals
        self.pendingQuestions = pendingQuestions
    }
}

public struct MicroRemoteThreadsListResultPayload: Codable, Equatable, Sendable {
    public var revision: Int
    public var threads: [MicroRemoteThreadDTO]
    public var nextCursor: String?
    public var totalCount: Int

    public init(revision: Int, threads: [MicroRemoteThreadDTO], nextCursor: String? = nil, totalCount: Int) {
        self.revision = revision
        self.threads = threads
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}

public struct MicroRemoteCommandAckPayload: Codable, Equatable, Sendable {
    public var commandType: String
    public var status: MicroRemoteCommandOutcomeStatus
    public var revision: Int
    public var threadID: String?
    public var turnID: String?
    public var approvalRequestID: String?
    public var errorCode: String?
    public var message: String?

    public init(
        commandType: String,
        status: MicroRemoteCommandOutcomeStatus,
        revision: Int,
        threadID: String? = nil,
        turnID: String? = nil,
        approvalRequestID: String? = nil,
        errorCode: String? = nil,
        message: String? = nil
    ) {
        self.commandType = commandType
        self.status = status
        self.revision = revision
        self.threadID = threadID
        self.turnID = turnID
        self.approvalRequestID = approvalRequestID
        self.errorCode = errorCode
        self.message = message
    }
}
