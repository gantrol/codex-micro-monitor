import CryptoKit
import Darwin
import Foundation
import MicroCore
import MicroRemote
import MicroShared
import Network
import OSLog
import Security

actor MacRemoteHost {
    private struct ActiveSession {
        let sessionID: String
        var deviceID: String?
        var deviceName: String
        var devicePublicKey: String?
        var role: MicroRemoteRole
        var isAuthenticated: Bool
        var isRelay: Bool
        var outboundSeq: UInt64
        let sendText: @Sendable (String) -> Void
        let closeTransport: @Sendable () -> Void
    }

    private let logger = Logger(subsystem: "com.gantrol.codex-micro-monitor", category: "remote-host")
    private let backend: DesktopBackend
    private let storeDB: MicroRemoteStoreDB
    private let hostIdentity: MicroHostIdentityRecord
    private let queue = DispatchQueue(label: "com.gantrol.micro.remote-host", qos: .userInitiated)

    private var listener: NWListener?
    private var listeningPort: UInt16 = MicroRemoteConstants.defaultPort
    private var certPinSHA256: String?
    private var tlsEnabled = false

    private var sessions: [String: ActiveSession] = [:]
    private var activeWriterDeviceID: String?
    private var activeWriterName: String?

    private var revision: Int = 1
    private var selectedThreadID: String?
    private var keypadSlotCount: Int = 6
    private var cachedSnapshot: [String: Any]?
    private var cachedApprovalsByThread: [String: [[String: Any]]] = [:]
    private var pollTask: Task<Void, Never>?

    private var relayURLString: String?
    private var relayTask: URLSessionWebSocketTask?
    private var relayLoopTask: Task<Void, Never>?

    init(backend: DesktopBackend) {
        self.backend = backend
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dbURL = appSupport
            .appendingPathComponent("CodexMicroMonitor", isDirectory: true)
            .appendingPathComponent("remote_host_v2.sqlite3")
        let db = (try? MicroRemoteStoreDB(databaseURL: dbURL))
            ?? (try! MicroRemoteStoreDB(databaseURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remote_host_v2.sqlite3")))
        self.storeDB = db
        self.hostIdentity = db.loadOrCreateHostIdentity()
    }

    func start(port: UInt16 = MicroRemoteConstants.defaultPort, relayURL: String? = nil) {
        if listener == nil {
            startDirectListener(port: port)
        }
        if let relayURL, !relayURL.isEmpty {
            configureRelay(url: relayURL)
        }
        if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { break }
                    await self.periodicBroadcastIfNeeded()
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        relayLoopTask?.cancel()
        relayLoopTask = nil
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        listener?.cancel()
        listener = nil
        for session in sessions.values {
            session.closeTransport()
        }
        sessions.removeAll()
    }

    func statusSummary() -> [String: Any] {
        let devices = storeDB.listPairedDevices().map { record -> [String: Any] in
            [
                "deviceId": record.deviceID,
                "deviceName": record.deviceName,
                "platform": record.platform,
                "pairedAtMs": record.pairedAtMs,
                "lastSeenAtMs": record.lastSeenAtMs,
            ]
        }
        return [
            "running": listener != nil,
            "hostId": hostIdentity.hostID,
            "hostName": Host.current().localizedName ?? "Mac",
            "port": Int(listeningPort),
            "tlsEnabled": tlsEnabled,
            "certPinSHA256": certPinSHA256 ?? (NSNull() as Any),
            "endpoints": Self.discoverEndpoints(port: listeningPort, tls: tlsEnabled),
            "relayURL": relayURLString ?? (NSNull() as Any),
            "pairedDevices": devices,
            "connectedCount": sessions.values.filter { $0.isAuthenticated }.count,
            "activeWriterDeviceId": activeWriterDeviceID ?? (NSNull() as Any),
        ]
    }

    func createPairingInfo(mode: MicroRemoteConnectionMode = .directTailscale, relayURL: String? = nil) -> [String: Any] {
        if listener == nil {
            start(port: listeningPort, relayURL: relayURL)
        } else if let relayURL, !relayURL.isEmpty {
            configureRelay(url: relayURL)
        }
        let issued = storeDB.issuePairingToken(ttlSeconds: 300)
        let endpoints = Self.discoverEndpoints(port: listeningPort, tls: tlsEnabled)
        let payload = MicroRemotePairPayload(
            version: MicroRemoteConstants.protocolVersion,
            mode: mode,
            hostID: hostIdentity.hostID,
            hostName: Host.current().localizedName ?? "Mac",
            platform: .macos,
            endpoints: endpoints,
            relayURL: relayURL ?? relayURLString,
            certPinSHA256: certPinSHA256,
            hostPublicKey: hostIdentity.publicKeyBase64,
            pairingToken: issued.token,
            expiresAtMs: issued.expiresAtMs
        )
        let uri = payload.toURIString()
        let jsonData = (try? JSONEncoder().encode(payload)) ?? Data()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        return [
            "uri": uri,
            "json": jsonString,
            "hostId": payload.hostID,
            "hostName": payload.hostName,
            "endpoints": endpoints,
            "pairingToken": issued.token,
            "expiresAtMs": issued.expiresAtMs,
            "certPinSHA256": certPinSHA256 ?? (NSNull() as Any),
            "hostPublicKey": hostIdentity.publicKeyBase64,
        ]
    }

    func revokeDevice(deviceID: String) -> [String: Any] {
        storeDB.revokeDevice(deviceID: deviceID)
        for (sid, session) in sessions where session.deviceID == deviceID {
            let revokedFrame: [String: Any] = [
                "type": "auth.revoked",
                "v": MicroRemoteConstants.protocolVersion,
                "payload": [
                    "deviceID": deviceID,
                    "reason": "Device access was revoked on Host.",
                ],
            ]
            sendFrame(revokedFrame, toSessionID: sid)
            session.closeTransport()
            sessions.removeValue(forKey: sid)
        }
        if activeWriterDeviceID == deviceID {
            activeWriterDeviceID = nil
            activeWriterName = nil
            reassignWriterLeaseIfNeeded()
        }
        return statusSummary()
    }

    // MARK: - Direct Network.framework Listener (Scheme A)

    private func startDirectListener(port: UInt16) {
        let parameters: NWParameters
        if let (tlsOptions, pin) = Self.makeTLSOptionsIfAvailable() {
            parameters = NWParameters(tls: tlsOptions)
            self.certPinSHA256 = pin
            self.tlsEnabled = true
        } else {
            parameters = NWParameters.tcp
            self.certPinSHA256 = nil
            self.tlsEnabled = false
        }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 1_048_576
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        guard let created = try? NWListener(using: parameters, on: nwPort) else {
            logger.error("Failed to create NWListener on port \(port, privacy: .public)")
            return
        }

        self.listeningPort = port
        created.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let actualPort = created.port?.rawValue {
                Task { await self.updateActualPort(actualPort) }
            }
        }
        created.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.acceptConnection(connection) }
        }
        created.start(queue: queue)
        self.listener = created
    }

    private func updateActualPort(_ port: UInt16) {
        self.listeningPort = port
        logger.notice("MacRemoteHost listening on port \(port, privacy: .public)")
    }

    private func acceptConnection(_ connection: NWConnection) {
        let sessionID = "ws-" + UUID().uuidString.lowercased()
        let session = ActiveSession(
            sessionID: sessionID,
            deviceID: nil,
            deviceName: "iOS Client",
            devicePublicKey: nil,
            role: .readOnly,
            isAuthenticated: false,
            isRelay: false,
            outboundSeq: 0,
            sendText: { text in
                guard let data = text.data(using: .utf8) else { return }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
                connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
            },
            closeTransport: {
                connection.cancel()
            }
        )
        sessions[sessionID] = session

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { await self.removeSession(sessionID) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNextMessage(on: connection, sessionID: sessionID)
    }

    private nonisolated func receiveNextMessage(on connection: NWConnection, sessionID: String) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if let error {
                self.logger.debug("WebSocket receive ended: \(error.localizedDescription, privacy: .public)")
                Task { await self.removeSession(sessionID) }
                return
            }
            if let data = content, !data.isEmpty,
               let text = String(data: data, encoding: .utf8) {
                Task { await self.handleIncomingRawText(text, fromSessionID: sessionID) }
            }
            if let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               wsMeta.opcode == .close {
                Task { await self.removeSession(sessionID) }
                return
            }
            self.receiveNextMessage(on: connection, sessionID: sessionID)
        }
    }

    private func removeSession(_ sessionID: String) {
        guard let removed = sessions.removeValue(forKey: sessionID) else { return }
        if let deviceID = removed.deviceID, activeWriterDeviceID == deviceID {
            let stillConnected = sessions.values.contains { $0.deviceID == deviceID && $0.isAuthenticated }
            if !stillConnected {
                activeWriterDeviceID = nil
                activeWriterName = nil
                reassignWriterLeaseIfNeeded()
            }
        }
    }

    private func reassignWriterLeaseIfNeeded() {
        guard activeWriterDeviceID == nil else { return }
        if let firstAuth = sessions.values.first(where: { $0.isAuthenticated && $0.deviceID != nil }) {
            activeWriterDeviceID = firstAuth.deviceID
            activeWriterName = firstAuth.deviceName
            for key in sessions.keys {
                if sessions[key]?.deviceID == activeWriterDeviceID {
                    sessions[key]?.role = .readWrite
                }
            }
            broadcastLeaseState()
        }
    }

    // MARK: - Outbound Relay Client (Scheme B)

    func configureRelay(url: String) {
        self.relayURLString = url
        relayLoopTask?.cancel()
        relayTask?.cancel(with: .goingAway, reason: nil)

        guard var components = URLComponents(string: url) else { return }
        var items = components.queryItems ?? []
        items.removeAll { ["role", "hostId"].contains($0.name) }
        items.append(URLQueryItem(name: "role", value: "host"))
        items.append(URLQueryItem(name: "hostId", value: hostIdentity.hostID))
        components.queryItems = items
        guard let targetURL = components.url else { return }

        relayLoopTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { break }
                await self.runRelaySession(url: targetURL)
                attempt += 1
                let delaySeconds = min(30.0, pow(1.8, Double(min(attempt, 6))))
                try? await Task.sleep(for: .milliseconds(Int(delaySeconds * 1000)))
            }
        }
    }

    private func runRelaySession(url: URL) async {
        let urlSession = URLSession(configuration: .default)
        let ws = urlSession.webSocketTask(with: url)
        self.relayTask = ws
        ws.resume()

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                let text: String? = switch message {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
                }
                if let text {
                    await handleIncomingRelayFrame(text, ws: ws)
                }
            } catch {
                break
            }
        }
    }

    private func handleIncomingRelayFrame(_ text: String, ws: URLSessionWebSocketTask) async {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MicroRelayEnvelope.self, from: data),
              envelope.type == "relay.envelope",
              envelope.hostID == hostIdentity.hostID else {
            return
        }
        guard let plaintext = try? MicroRemoteCrypto.openRelayEnvelope(
            envelope,
            recipientPrivateKeyBase64: hostIdentity.privateKeyBase64
        ),
        let innerText = String(data: plaintext, encoding: .utf8) else {
            return
        }

        let relaySessionID = "relay-\(envelope.deviceID)"
        if sessions[relaySessionID] == nil {
            let deviceID = envelope.deviceID
            let senderPubKey = envelope.senderPublicKey
            sessions[relaySessionID] = ActiveSession(
                sessionID: relaySessionID,
                deviceID: deviceID,
                deviceName: "Relay Device",
                devicePublicKey: senderPubKey,
                role: .readOnly,
                isAuthenticated: false,
                isRelay: true,
                outboundSeq: 0,
                sendText: { [weak self] plainOut in
                    guard let self else { return }
                    Task {
                        await self.sendEncryptedRelayText(
                            plainOut,
                            sessionID: relaySessionID,
                            deviceID: deviceID,
                            recipientPublicKeyBase64: senderPubKey,
                            ws: ws
                        )
                    }
                },
                closeTransport: {}
            )
        } else {
            sessions[relaySessionID]?.devicePublicKey = envelope.senderPublicKey
        }

        await handleIncomingRawText(innerText, fromSessionID: relaySessionID)
    }

    private func sendEncryptedRelayText(
        _ plainText: String,
        sessionID: String,
        deviceID: String,
        recipientPublicKeyBase64: String,
        ws: URLSessionWebSocketTask
    ) {
        guard var session = sessions[sessionID] else { return }
        session.outboundSeq += 1
        sessions[sessionID] = session
        guard let envelope = try? MicroRemoteCrypto.sealRelayEnvelope(
            plaintext: Data(plainText.utf8),
            sessionID: sessionID,
            hostID: hostIdentity.hostID,
            deviceID: deviceID,
            seq: session.outboundSeq,
            senderPrivateKeyBase64: hostIdentity.privateKeyBase64,
            recipientPublicKeyBase64: recipientPublicKeyBase64
        ),
        let data = try? JSONEncoder().encode(envelope),
        let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        ws.send(.string(jsonString)) { _ in }
    }

    // MARK: - Protocol v2 Message Dispatch

    private func handleIncomingRawText(_ text: String, fromSessionID sessionID: String) async {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = raw["type"] as? String else {
            return
        }
        let requestID = raw["requestID"] as? String
        let payload = raw["payload"] as? [String: Any] ?? [:]

        switch type {
        case "pair.exchange":
            handlePairExchange(payload: payload, requestID: requestID, sessionID: sessionID)

        case "hello":
            await handleHello(payload: payload, requestID: requestID, sessionID: sessionID)

        case "ping":
            let clientTs = (payload["clientTimestampMs"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
            sendFrame([
                "type": "pong",
                "v": MicroRemoteConstants.protocolVersion,
                "requestID": requestID as Any,
                "payload": [
                    "clientTimestampMs": clientTs,
                    "serverTimestampMs": Int64(Date().timeIntervalSince1970 * 1000),
                ],
            ], toSessionID: sessionID)

        case "session.takeover":
            guard isSessionAuthenticated(sessionID) else {
                sendError(to: sessionID, requestID: requestID, code: "unauthorized", message: "Authenticate before requesting takeover.")
                return
            }
            handleTakeover(sessionID: sessionID, requestID: requestID)

        case "state.requestSnapshot":
            guard isSessionAuthenticated(sessionID) else {
                sendError(to: sessionID, requestID: requestID, code: "unauthorized", message: "Authenticate before requesting snapshot.")
                return
            }
            let snap = await buildSnapshotPayload()
            sendFrame([
                "type": "state.snapshot",
                "v": MicroRemoteConstants.protocolVersion,
                "requestID": requestID as Any,
                "payload": snap,
            ], toSessionID: sessionID)

        case "threads.list":
            guard isSessionAuthenticated(sessionID) else {
                sendError(to: sessionID, requestID: requestID, code: "unauthorized", message: "Authenticate before listing threads.")
                return
            }
            let listPayload = await buildThreadsListPayload(request: payload)
            sendFrame([
                "type": "threads.list.result",
                "v": MicroRemoteConstants.protocolVersion,
                "requestID": requestID as Any,
                "payload": listPayload,
            ], toSessionID: sessionID)

        case "thread.detail.read":
            guard isSessionAuthenticated(sessionID) else {
                sendError(to: sessionID, requestID: requestID, code: "unauthorized", message: "Authenticate before reading thread detail.")
                return
            }
            await handleThreadDetailRead(payload: payload, requestID: requestID, sessionID: sessionID)

        case "command.queryResult":
            guard isSessionAuthenticated(sessionID),
                  let deviceID = sessions[sessionID]?.deviceID else {
                sendError(to: sessionID, requestID: requestID, code: "unauthorized", message: "Authenticate before querying command results.")
                return
            }
            let targetReqID = (payload["targetRequestID"] as? String) ?? requestID ?? ""
            if let ack = storeDB.queryCommand(deviceID: deviceID, requestID: targetReqID) {
                sendCommandAck(ack, requestID: targetReqID, toSessionID: sessionID)
            } else {
                let unknownAck = MicroRemoteCommandAckPayload(
                    commandType: "unknown",
                    status: .unknown,
                    revision: revision,
                    errorCode: "command_not_found",
                    message: "No ledger record found for request \(targetReqID)."
                )
                sendCommandAck(unknownAck, requestID: targetReqID, toSessionID: sessionID)
            }

        default:
            await handleMutatingCommand(type: type, payload: payload, requestID: requestID, sessionID: sessionID)
        }
    }

    private func handlePairExchange(payload: [String: Any], requestID: String?, sessionID: String) {
        let pairingToken = (payload["pairingToken"] as? String) ?? ""
        let deviceID = (payload["deviceID"] as? String) ?? ("ios-" + UUID().uuidString.lowercased().prefix(8))
        let deviceName = (payload["deviceName"] as? String) ?? "iPhone"
        let platform = (payload["platform"] as? String) ?? "ios"
        let devicePublicKey = payload["devicePublicKey"] as? String

        guard let deviceToken = storeDB.exchangePairingToken(
            rawPairingToken: pairingToken,
            deviceID: deviceID,
            deviceName: deviceName,
            platform: platform,
            devicePublicKey: devicePublicKey
        ) else {
            sendError(to: sessionID, requestID: requestID, code: "invalid_pairing_token", message: "Pairing token is invalid, expired, or already used.")
            return
        }

        let endpoints = Self.discoverEndpoints(port: listeningPort, tls: tlsEnabled)
        var accepted: [String: Any] = [
            "hostID": hostIdentity.hostID,
            "hostName": Host.current().localizedName ?? "Mac",
            "hostPlatform": MicroRemotePlatform.macos.rawValue,
            "deviceID": deviceID,
            "deviceToken": deviceToken,
            "hostPublicKey": hostIdentity.publicKeyBase64,
            "endpoints": endpoints,
        ]
        if let certPinSHA256 { accepted["certPinSHA256"] = certPinSHA256 }
        if let relayURLString { accepted["relayURL"] = relayURLString }

        sendFrame([
            "type": "pair.accepted",
            "v": MicroRemoteConstants.protocolVersion,
            "requestID": requestID as Any,
            "payload": accepted,
        ], toSessionID: sessionID)
    }

    private func handleHello(payload: [String: Any], requestID: String?, sessionID: String) async {
        guard var session = sessions[sessionID] else { return }
        let deviceID = (payload["deviceID"] as? String) ?? "legacy-ios-device"
        let deviceName = (payload["deviceName"] as? String) ?? "iPhone"
        let rawToken = (payload["deviceToken"] as? String) ?? (payload["token"] as? String) ?? ""
        let pubKey = payload["devicePublicKey"] as? String

        if let record = storeDB.authenticateDevice(deviceID: deviceID, rawDeviceToken: rawToken) {
            session.deviceID = record.deviceID
            session.deviceName = record.deviceName
            if let pubKey { session.devicePublicKey = pubKey }
            session.isAuthenticated = true
        } else if let exchangedToken = storeDB.exchangePairingToken(
            rawPairingToken: rawToken,
            deviceID: deviceID,
            deviceName: deviceName,
            platform: "ios",
            devicePublicKey: pubKey
        ) {
            // Allow one-step hello with a fresh pairing token for seamless v1/manual entry
            _ = storeDB.authenticateDevice(deviceID: deviceID, rawDeviceToken: exchangedToken)
            session.deviceID = deviceID
            session.deviceName = deviceName
            session.devicePublicKey = pubKey
            session.isAuthenticated = true
        } else {
            sendError(to: sessionID, requestID: requestID, code: "auth_failed", message: "Invalid or revoked device credentials.")
            return
        }

        if activeWriterDeviceID == nil || activeWriterDeviceID == deviceID {
            activeWriterDeviceID = deviceID
            activeWriterName = session.deviceName
            session.role = .readWrite
        } else {
            session.role = .readOnly
        }
        sessions[sessionID] = session

        sendFrame([
            "type": "hello.ok",
            "v": MicroRemoteConstants.protocolVersion,
            "requestID": requestID as Any,
            "payload": [
                "protocolVersion": MicroRemoteConstants.protocolVersion,
                "minSupportedVersion": MicroRemoteConstants.minSupportedVersion,
                "hostID": hostIdentity.hostID,
                "hostName": Host.current().localizedName ?? "Mac",
                "hostPlatform": MicroRemotePlatform.macos.rawValue,
                "role": session.role.rawValue,
                "activeWriterDeviceID": activeWriterDeviceID ?? (NSNull() as Any),
                "activeWriterName": activeWriterName ?? (NSNull() as Any),
                "canTakeover": true,
            ],
        ], toSessionID: sessionID)

        let snap = await buildSnapshotPayload()
        sendFrame([
            "type": "state.snapshot",
            "v": MicroRemoteConstants.protocolVersion,
            "payload": snap,
        ], toSessionID: sessionID)
    }

    private func handleTakeover(sessionID: String, requestID: String?) {
        guard let session = sessions[sessionID], let deviceID = session.deviceID else { return }
        activeWriterDeviceID = deviceID
        activeWriterName = session.deviceName
        for key in sessions.keys {
            sessions[key]?.role = (sessions[key]?.deviceID == deviceID) ? .readWrite : .readOnly
        }
        broadcastLeaseState(requestID: requestID)
    }

    private func broadcastLeaseState(requestID: String? = nil) {
        for (sid, session) in sessions where session.isAuthenticated {
            sendFrame([
                "type": "session.lease",
                "v": MicroRemoteConstants.protocolVersion,
                "requestID": requestID as Any,
                "payload": [
                    "role": session.role.rawValue,
                    "activeWriterDeviceID": activeWriterDeviceID ?? (NSNull() as Any),
                    "activeWriterName": activeWriterName ?? (NSNull() as Any),
                    "canTakeover": true,
                ],
            ], toSessionID: sid)
        }
    }

    private func handleThreadDetailRead(payload: [String: Any], requestID: String?, sessionID: String) async {
        guard let threadID = payload["threadID"] as? String, !threadID.isEmpty else {
            sendError(to: sessionID, requestID: requestID, code: "invalid_thread", message: "Missing threadID.")
            return
        }
        do {
            let raw = try await backend.execute("get_keypad_thread_detail", arguments: ["thread_id": threadID])
            let runtimeStatus = raw["runtimeStatus"] as? [String: Any] ?? [:]
            let approvalsRaw = raw["approvals"] as? [[String: Any]] ?? []
            cachedApprovalsByThread[threadID] = approvalsRaw

            let approvalsOut = approvalsRaw.map { item -> [String: Any] in
                [
                    "id": item["id"] as? String ?? "",
                    "kind": item["kind"] as? String ?? "other",
                    "summary": item["summary"] as? String ?? "",
                    "commandText": item["commandText"] ?? (NSNull() as Any),
                    "cwd": item["cwd"] ?? (NSNull() as Any),
                    "filePaths": item["filePaths"] as? [String] ?? [],
                    "approvalContentHash": item["approvalContentHash"] as? String ?? "",
                    "createdAtMs": item["createdAtMs"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000),
                ]
            }
            let questionsRaw = raw["pendingQuestions"] as? [[String: Any]] ?? []
            let status = Self.mapRemoteStatus(
                runtimeStatus: runtimeStatus,
                hasPendingApproval: !approvalsOut.isEmpty,
                hasPendingQuestion: !questionsRaw.isEmpty,
                hasUnread: false
            )

            sendFrame([
                "type": "thread.detail.result",
                "v": MicroRemoteConstants.protocolVersion,
                "requestID": requestID as Any,
                "payload": [
                    "threadID": threadID,
                    "revision": revision,
                    "activeTurnID": raw["activeTurnId"] ?? (NSNull() as Any),
                    "status": status,
                    "canSubmitText": raw["canSubmit"] as? Bool ?? false,
                    "latestReply": raw["latestReply"] ?? (NSNull() as Any),
                    "approvals": approvalsOut,
                    "pendingQuestions": questionsRaw,
                ],
            ], toSessionID: sessionID)
        } catch {
            sendError(to: sessionID, requestID: requestID, code: "detail_unavailable", message: error.localizedDescription)
        }
    }

    // MARK: - Mutating Commands & SQLite Ledger

    private func handleMutatingCommand(
        type: String,
        payload: [String: Any],
        requestID: String?,
        sessionID: String
    ) async {
        guard let session = sessions[sessionID], session.isAuthenticated, let deviceID = session.deviceID else {
            sendError(to: sessionID, requestID: requestID, code: "unauthorized", message: "Authenticate before sending control commands.")
            return
        }
        guard session.role == .readWrite else {
            let rejected = MicroRemoteCommandAckPayload(
                commandType: type,
                status: .rejected,
                revision: revision,
                errorCode: "read_only_lease",
                message: "Session is in read-only mode. Take over control first."
            )
            sendCommandAck(rejected, requestID: requestID, toSessionID: sessionID)
            return
        }

        let reqID = requestID ?? UUID().uuidString
        let targetThreadID = (payload["threadID"] as? String) ?? selectedThreadID
        let targetTurnID = payload["turnID"] as? String
        let approvalRequestID = payload["approvalRequestID"] as? String
        let payloadHash = Self.canonicalHash(type: type, payload: payload, defaultThreadID: targetThreadID)

        let beginOutcome = storeDB.beginOrReuseCommand(
            deviceID: deviceID,
            requestID: reqID,
            payloadHash: payloadHash,
            commandType: type,
            revision: revision,
            threadID: targetThreadID,
            turnID: targetTurnID,
            approvalRequestID: approvalRequestID
        )

        switch beginOutcome {
        case .payloadConflict:
            sendError(to: sessionID, requestID: reqID, code: "payload_conflict", message: "Request ID reused with different command payload.")
            return
        case .existing(let ack):
            sendCommandAck(ack, requestID: reqID, toSessionID: sessionID)
            return
        case .started:
            break
        }

        var outcomeStatus: MicroRemoteCommandOutcomeStatus = .completed
        var errorCode: String?
        var errorMessage: String?

        do {
            switch type {
            case "thread.select":
                guard let threadID = payload["threadID"] as? String, !threadID.isEmpty else {
                    throw CodexClientError.invalid("Missing threadID.")
                }
                selectedThreadID = threadID
                if payload["openInDesktop"] as? Bool == true {
                    _ = try? await backend.execute("open_keypad_thread", arguments: ["thread_id": threadID])
                }

            case "settings.setModel":
                guard let threadID = targetThreadID,
                      let model = payload["model"] as? String, !model.isEmpty else {
                    throw CodexClientError.invalid("Missing threadID or model.")
                }
                var args: [String: Any] = ["thread_id": threadID, "model": model]
                if let effort = payload["effort"] as? String, !effort.isEmpty {
                    args["effort"] = effort
                }
                _ = try await backend.execute("set_keypad_model", arguments: args)

            case "settings.setEffort":
                guard let threadID = targetThreadID,
                      let effort = payload["effort"] as? String, !effort.isEmpty else {
                    throw CodexClientError.invalid("Missing threadID or effort.")
                }
                _ = try await backend.execute("set_keypad_reasoning", arguments: ["thread_id": threadID, "effort": effort])

            case "settings.stepEffort":
                guard let threadID = targetThreadID else {
                    throw CodexClientError.invalid("Missing threadID.")
                }
                let delta = (payload["delta"] as? Int) ?? 1
                let steppedEffort = try await resolveSteppedEffort(threadID: threadID, delta: delta)
                _ = try await backend.execute("set_keypad_reasoning", arguments: ["thread_id": threadID, "effort": steppedEffort])

            case "settings.setFastMode":
                guard let threadID = targetThreadID,
                      let enabled = payload["enabled"] as? Bool else {
                    throw CodexClientError.invalid("Missing threadID or enabled.")
                }
                _ = try await backend.execute("set_keypad_fast", arguments: ["thread_id": threadID, "enabled": enabled])

            case "settings.setPlanMode":
                guard let threadID = targetThreadID,
                      let requestedPlan = payload["enabled"] as? Bool else {
                    throw CodexClientError.invalid("Missing threadID or enabled.")
                }
                let state = try await backend.execute("get_keypad_state", arguments: ["thread_id": threadID])
                let currentMode = (state["collaborationMode"] as? [String: Any])?["mode"] as? String
                let currentlyPlan = currentMode == "plan"
                if currentlyPlan != requestedPlan {
                    _ = try await backend.execute("toggle_keypad_plan", arguments: ["thread_id": threadID])
                }

            case "approval.accept", "approval.decline":
                guard let threadID = targetThreadID,
                      let reqApprovalID = approvalRequestID, !reqApprovalID.isEmpty else {
                    throw CodexClientError.invalid("Missing threadID or approvalRequestID.")
                }
                let decision = (type == "approval.accept") ? "accept" : "decline"
                var args: [String: Any] = [
                    "thread_id": threadID,
                    "request_id": reqApprovalID,
                    "decision": decision,
                ]
                if let expectedHash = payload["approvalContentHash"] as? String, !expectedHash.isEmpty {
                    let detail = try await backend.execute("get_keypad_thread_detail", arguments: ["thread_id": threadID])
                    let approvals = detail["approvals"] as? [[String: Any]] ?? []
                    guard let matched = approvals.first(where: { $0["id"] as? String == reqApprovalID }),
                          (matched["approvalContentHash"] as? String) == expectedHash else {
                        throw CodexClientError.staleTarget
                    }
                    if let method = matched["method"], let details = matched["details"] {
                        args["expected_request"] = ["method": method, "details": details]
                    }
                }
                _ = try await backend.execute("reply_keypad_approval", arguments: args)

            case "turn.stop":
                guard let threadID = targetThreadID,
                      let turnID = targetTurnID, !turnID.isEmpty else {
                    throw CodexClientError.invalid("Missing threadID or turnID.")
                }
                _ = try await backend.execute("stop_keypad_turn", arguments: [
                    "thread_id": threadID,
                    "turn_id": turnID,
                ])

            case "turn.sendText":
                guard let threadID = targetThreadID,
                      let text = payload["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CodexClientError.invalid("Missing threadID or non-empty text.")
                }
                _ = try await backend.execute("send_keypad_message", arguments: [
                    "thread_id": threadID,
                    "text": text,
                ])

            default:
                throw CodexClientError.unsupported("Unsupported remote command: \(type)")
            }
        } catch CodexClientError.outcomeUnknown {
            outcomeStatus = .unknown
            errorCode = "outcome_unknown"
            errorMessage = "Command dispatch outcome could not be verified. Check snapshot before retrying."
        } catch CodexClientError.staleTarget {
            outcomeStatus = .rejected
            errorCode = "stale_target"
            errorMessage = "Target thread or approval state changed before execution."
        } catch {
            outcomeStatus = .rejected
            errorCode = "command_rejected"
            errorMessage = error.localizedDescription
        }

        revision += 1
        let finalAck = storeDB.completeCommand(
            deviceID: deviceID,
            requestID: reqID,
            status: outcomeStatus,
            revision: revision,
            threadID: targetThreadID,
            turnID: targetTurnID,
            approvalRequestID: approvalRequestID,
            errorCode: errorCode,
            message: errorMessage
        ) ?? MicroRemoteCommandAckPayload(
            commandType: type,
            status: outcomeStatus,
            revision: revision,
            threadID: targetThreadID,
            turnID: targetTurnID,
            approvalRequestID: approvalRequestID,
            errorCode: errorCode,
            message: errorMessage
        )

        sendCommandAck(finalAck, requestID: reqID, toSessionID: sessionID)
        let snap = await buildSnapshotPayload()
        broadcastSnapshot(snap)
    }

    private func resolveSteppedEffort(threadID: String, delta: Int) async throws -> String {
        let state = try await backend.execute("get_keypad_state", arguments: ["thread_id": threadID])
        let modelsResult = try await backend.execute("get_keypad_models", arguments: [:])
        let rows = modelsResult["data"] as? [[String: Any]] ?? []
        guard let currentModel = state["model"] as? String,
              let def = rows.first(where: { $0["model"] as? String == currentModel }) else {
            throw CodexClientError.unavailable("Current thread model is unavailable.")
        }
        let efforts = (def["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
            .compactMap { $0["reasoningEffort"] as? String }
        guard !efforts.isEmpty else {
            throw CodexClientError.unavailable("No supported reasoning efforts for current model.")
        }
        let currentEffort = (state["effort"] as? String) ?? (def["defaultReasoningEffort"] as? String) ?? efforts[0]
        let idx = efforts.firstIndex(of: currentEffort) ?? 0
        let nextIdx = max(0, min(efforts.count - 1, idx + (delta >= 0 ? 1 : -1)))
        return efforts[nextIdx]
    }

    // MARK: - Snapshot & Threads List Projection

    private func periodicBroadcastIfNeeded() async {
        guard sessions.values.contains(where: { $0.isAuthenticated }) else { return }
        let snap = await buildSnapshotPayload()
        broadcastSnapshot(snap)
    }

    private func broadcastSnapshot(_ snap: [String: Any]) {
        for (sid, session) in sessions where session.isAuthenticated {
            sendFrame([
                "type": "state.snapshot",
                "v": MicroRemoteConstants.protocolVersion,
                "payload": snap,
            ], toSessionID: sid)
        }
    }

    private func buildSnapshotPayload() async -> [String: Any] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let listResult = (try? await backend.execute("list_keypad_threads", arguments: ["include_priority": true, "include_pinned": true])) ?? [:]
        let allRows = (listResult["threads"] as? [[String: Any]]) ?? []
        let modelsRaw = (try? await backend.execute("get_keypad_models", arguments: [:]))?["data"] as? [[String: Any]] ?? []
        let usageRaw = (try? await backend.execute("get_keypad_usage", arguments: [:])) ?? [:]

        var modelNames: [String] = []
        var effortsByModel: [String: [String]] = [:]
        for row in modelsRaw where row["hidden"] as? Bool != true {
            guard let modelID = row["model"] as? String, !modelID.isEmpty else { continue }
            modelNames.append(modelID)
            let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            effortsByModel[modelID] = efforts
        }

        if selectedThreadID == nil || !allRows.contains(where: { $0["id"] as? String == selectedThreadID }) {
            selectedThreadID = allRows.first?["id"] as? String
        }

        var selectedState: [String: Any]?
        var selectedDetail: [String: Any]?
        if let selectedThreadID {
            selectedState = try? await backend.execute("get_keypad_state", arguments: ["thread_id": selectedThreadID])
            selectedDetail = try? await backend.execute("get_keypad_thread_detail", arguments: ["thread_id": selectedThreadID])
        }

        let slotLimit = max(6, min(14, keypadSlotCount))
        var projectedThreads: [[String: Any]] = []
        for (index, row) in allRows.prefix(slotLimit).enumerated() {
            guard let id = row["id"] as? String else { continue }
            let isSelected = (id == selectedThreadID)
            let detail = isSelected ? selectedDetail : nil
            let state = isSelected ? selectedState : nil
            projectedThreads.append(
                Self.projectThreadRow(
                    row: row,
                    slotIndex: index,
                    state: state,
                    detail: detail,
                    nowMs: nowMs
                )
            )
        }

        let topModel = (selectedState?["model"] as? String)
        let topEffort = (selectedState?["effort"] as? String)
        let topFast: Any = {
            guard let selectedState else { return NSNull() }
            if let tier = selectedState["serviceTier"] as? String {
                return ["fast", "priority"].contains(tier)
            }
            if selectedState["serviceTier"] is NSNull {
                return false
            }
            return NSNull()
        }()
        let topPlan: Any = {
            guard let selectedState,
                  let collab = selectedState["collaborationMode"] as? [String: Any],
                  let mode = collab["mode"] as? String else {
                return NSNull()
            }
            return mode == "plan"
        }()

        let quota = Self.projectQuota(usageRaw, nowMs: nowMs)
        revision += 1

        let snapshot: [String: Any] = [
            "revision": revision,
            "hostID": hostIdentity.hostID,
            "hostName": Host.current().localizedName ?? "Mac",
            "hostPlatform": MicroRemotePlatform.macos.rawValue,
            "snapshotUpdatedAtMs": nowMs,
            "keypadSlotCount": slotLimit,
            "selectedThreadID": selectedThreadID ?? (NSNull() as Any),
            "model": topModel ?? (NSNull() as Any),
            "effort": topEffort ?? (NSNull() as Any),
            "fastMode": topFast,
            "planMode": topPlan,
            "modelCatalog": [
                "models": modelNames,
                "effortsByModel": effortsByModel,
            ],
            "quota": quota,
            "threads": projectedThreads,
            "totalThreadCount": allRows.count,
        ]
        cachedSnapshot = snapshot
        return snapshot
    }

    private func buildThreadsListPayload(request: [String: Any]) async -> [String: Any] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let query = (request["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let offset = Int((request["cursor"] as? String) ?? "0") ?? 0
        let limit = max(1, min(100, (request["limit"] as? Int) ?? 30))

        let listResult = (try? await backend.execute("list_keypad_threads", arguments: ["include_priority": true, "include_pinned": true])) ?? [:]
        let allRows = (listResult["threads"] as? [[String: Any]]) ?? []

        let filtered = allRows.filter { row in
            guard !query.isEmpty else { return true }
            let title = (row["title"] as? String ?? "").lowercased()
            let cwd = (row["cwd"] as? String ?? "").lowercased()
            let id = (row["id"] as? String ?? "").lowercased()
            return title.contains(query) || cwd.contains(query) || id.contains(query)
        }

        let sliceStart = min(offset, filtered.count)
        let sliceEnd = min(sliceStart + limit, filtered.count)
        let pageRows = filtered[sliceStart..<sliceEnd]
        let nextCursor = sliceEnd < filtered.count ? String(sliceEnd) : nil

        let items = pageRows.enumerated().map { idx, row in
            Self.projectThreadRow(
                row: row,
                slotIndex: sliceStart + idx < keypadSlotCount ? (sliceStart + idx) : nil,
                state: nil,
                detail: nil,
                nowMs: nowMs
            )
        }

        return [
            "revision": revision,
            "threads": items,
            "nextCursor": nextCursor ?? (NSNull() as Any),
            "totalCount": filtered.count,
        ]
    }

    private static func projectThreadRow(
        row: [String: Any],
        slotIndex: Int?,
        state: [String: Any]?,
        detail: [String: Any]?,
        nowMs: Int64
    ) -> [String: Any] {
        let id = row["id"] as? String ?? ""
        let rawTitle = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? "Untitled" : rawTitle
        let cwd = row["cwd"] as? String ?? ""
        let workspaceName = cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cwd).lastPathComponent

        let runtimeStatus = (state?["runtimeStatus"] as? [String: Any]) ?? (row["status"] as? [String: Any]) ?? [:]
        let approvals = (detail?["approvals"] as? [[String: Any]]) ?? (state?["approvals"] as? [[String: Any]]) ?? []
        let hasPendingQuestion = (row["hasPendingQuestion"] as? Bool == true) ||
            (state?["hasPendingQuestion"] as? Bool == true) ||
            !((detail?["pendingQuestions"] as? [[String: Any]] ?? []).isEmpty)
        let hasUnread = (row["hasUnreadTurn"] as? Bool == true) || (state?["hasUnreadTurn"] as? Bool == true)
        let hasDraft = row["hasDraft"] as? Bool == true

        let status = mapRemoteStatus(
            runtimeStatus: runtimeStatus,
            hasPendingApproval: !approvals.isEmpty,
            hasPendingQuestion: hasPendingQuestion,
            hasUnread: hasUnread,
            fallbackErrorCode: row["errorCode"] as? String
        )

        var pendingApprovalObj: Any = NSNull()
        if let firstApp = approvals.first, let appID = firstApp["id"] as? String {
            let kind = (firstApp["kind"] as? String) ??
                ((firstApp["method"] as? String) == "item/commandExecution/requestApproval" ? "command" : "fileChange")
            let summary = (firstApp["summary"] as? String) ?? "Pending approval"
            let cmd = firstApp["commandText"] as? String
            let appCwd = firstApp["cwd"] as? String
            let paths = firstApp["filePaths"] as? [String] ?? []
            let hash = (firstApp["approvalContentHash"] as? String) ??
                MicroRemoteCrypto.computeApprovalContentHash(
                    requestID: appID,
                    kind: MicroRemoteApprovalKind(rawValue: kind) ?? .other,
                    commandText: cmd,
                    cwd: appCwd,
                    filePaths: paths
                )
            pendingApprovalObj = [
                "id": appID,
                "kind": kind,
                "summary": summary,
                "commandText": cmd ?? (NSNull() as Any),
                "cwd": appCwd ?? (NSNull() as Any),
                "filePaths": paths,
                "approvalContentHash": hash,
                "createdAtMs": nowMs,
            ]
        }

        let recencySec = (row["recencyAt"] as? Double) ?? (Double(nowMs) / 1000.0)
        let updatedAtMs = Int64(recencySec * 1000.0)

        let modelVal: Any = (state?["model"] as? String) ?? (NSNull() as Any)
        let effortVal: Any = (state?["effort"] as? String) ?? (NSNull() as Any)
        let fastVal: Any = {
            guard let state else { return NSNull() }
            if let tier = state["serviceTier"] as? String { return ["fast", "priority"].contains(tier) }
            if state["serviceTier"] is NSNull { return false }
            return NSNull()
        }()
        let planVal: Any = {
            guard let state,
                  let collab = state["collaborationMode"] as? [String: Any],
                  let mode = collab["mode"] as? String else { return NSNull() }
            return mode == "plan"
        }()

        return [
            "id": id,
            "slotIndex": slotIndex ?? (NSNull() as Any),
            "title": title,
            "workspaceName": workspaceName,
            "status": status,
            "activeTurnID": (state?["activeTurnId"] as? String) ?? (NSNull() as Any),
            "hasDraft": hasDraft,
            "hasUnreadCompletion": hasUnread,
            "pendingApprovalCount": approvals.count,
            "pendingQuestionCount": hasPendingQuestion ? 1 : 0,
            "updatedAtMs": updatedAtMs,
            "model": modelVal,
            "effort": effortVal,
            "fastMode": fastVal,
            "planMode": planVal,
            "pendingApproval": pendingApprovalObj,
        ]
    }

    private static func mapRemoteStatus(
        runtimeStatus: [String: Any],
        hasPendingApproval: Bool,
        hasPendingQuestion: Bool,
        hasUnread: Bool,
        fallbackErrorCode: String? = nil
    ) -> String {
        if hasPendingApproval { return "waiting" }
        if hasPendingQuestion { return "question" }
        let rawType = runtimeStatus["type"] as? String ?? ""
        let errorCode = (runtimeStatus["errorCode"] as? String) ?? fallbackErrorCode
        if rawType == "systemError" {
            if errorCode == "server_overloaded" {
                return "overloaded"
            }
            return "error"
        }
        if rawType == "active" {
            let flags = runtimeStatus["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") { return "waiting" }
            if flags.contains("waitingOnUserInput") { return "question" }
            return "running"
        }
        if rawType == "idle" {
            return hasUnread ? "completed" : "idle"
        }
        return "unknown"
    }

    private static func projectQuota(_ usage: [String: Any], nowMs: Int64) -> [String: Any] {
        let rateLimits = (usage["rateLimits"] as? [String: Any]) ?? usage
        let primary = rateLimits["primary"] as? [String: Any]
        let secondary = rateLimits["secondary"] as? [String: Any]

        func projectWindow(_ win: [String: Any]?, durationSec: Double) -> [String: Any] {
            guard let win,
                  let usedPercent = (win["usedPercent"] as? NSNumber)?.doubleValue else {
                return [
                    "remainingRatio": NSNull(),
                    "resetProgressRatio": NSNull(),
                    "resetAtMs": NSNull(),
                ]
            }
            let remaining = max(0.0, min(1.0, (100.0 - usedPercent) / 100.0))
            let resetsAtSec = (win["resetsAt"] as? NSNumber)?.doubleValue
            var resetProgress: Any = NSNull()
            var resetAtMs: Any = NSNull()
            if let resetsAtSec, resetsAtSec > 0 {
                let targetMs = Int64(resetsAtSec * 1000.0)
                resetAtMs = targetMs
                let remainingSec = max(0.0, resetsAtSec - (Double(nowMs) / 1000.0))
                resetProgress = max(0.0, min(1.0, 1.0 - (remainingSec / durationSec)))
            }
            return [
                "remainingRatio": remaining,
                "resetProgressRatio": resetProgress,
                "resetAtMs": resetAtMs,
            ]
        }

        return [
            "fiveHour": projectWindow(primary, durationSec: 5 * 3600),
            "sevenDay": projectWindow(secondary, durationSec: 7 * 86400),
            "updatedAtMs": nowMs,
        ]
    }

    // MARK: - Helpers

    private func isSessionAuthenticated(_ sessionID: String) -> Bool {
        sessions[sessionID]?.isAuthenticated == true
    }

    private func sendCommandAck(_ ack: MicroRemoteCommandAckPayload, requestID: String?, toSessionID sessionID: String) {
        var payloadDict: [String: Any] = [
            "commandType": ack.commandType,
            "status": ack.status.rawValue,
            "revision": ack.revision,
        ]
        if let threadID = ack.threadID { payloadDict["threadID"] = threadID }
        if let turnID = ack.turnID { payloadDict["turnID"] = turnID }
        if let approvalRequestID = ack.approvalRequestID { payloadDict["approvalRequestID"] = approvalRequestID }
        if let errorCode = ack.errorCode { payloadDict["errorCode"] = errorCode }
        if let message = ack.message { payloadDict["message"] = message }

        sendFrame([
            "type": "command.ack",
            "v": MicroRemoteConstants.protocolVersion,
            "requestID": requestID as Any,
            "payload": payloadDict,
        ], toSessionID: sessionID)
    }

    private func sendError(to sessionID: String, requestID: String?, code: String, message: String) {
        sendFrame([
            "type": "error",
            "v": MicroRemoteConstants.protocolVersion,
            "requestID": requestID as Any,
            "payload": [
                "code": code,
                "message": message,
            ],
        ], toSessionID: sessionID)
    }

    private func sendFrame(_ frame: [String: Any], toSessionID sessionID: String) {
        guard let session = sessions[sessionID],
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        session.sendText(text)
    }

    private static func canonicalHash(type: String, payload: [String: Any], defaultThreadID: String?) -> String {
        var fields: [(String, String)] = []
        if let tid = (payload["threadID"] as? String) ?? defaultThreadID {
            fields.append(("threadID", tid))
        }
        for key in ["model", "effort", "turnID", "approvalRequestID", "approvalContentHash", "text"] {
            if let val = payload[key] as? String {
                fields.append((key, val))
            }
        }
        if let enabled = payload["enabled"] as? Bool {
            fields.append(("enabled", enabled ? "true" : "false"))
        }
        if let delta = payload["delta"] as? Int {
            fields.append(("delta", String(delta)))
        }
        return MicroRemoteCrypto.computeCommandPayloadHash(type: type, fields: fields)
    }

    private static func makeTLSOptionsIfAvailable() -> (NWProtocolTLS.Options, String)? {
        guard let p12Path = ProcessInfo.processInfo.environment["CODEX_MICRO_TLS_P12_PATH"],
              !p12Path.isEmpty,
              let p12Data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) else {
            return nil
        }
        let password = ProcessInfo.processInfo.environment["CODEX_MICRO_TLS_P12_PASSWORD"] ?? ""
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var rawItems: CFArray?
        guard SecPKCS12Import(p12Data as CFData, options, &rawItems) == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            return nil
        }
        let secIdentity = identityRef as! SecIdentity
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &certRef) == errSecSuccess,
              let certRef,
              let secTrustIdentity = sec_identity_create(secIdentity) else {
            return nil
        }
        let certData = SecCertificateCopyData(certRef) as Data
        let pin = MicroRemoteCrypto.sha256Hex(certData)
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secTrustIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        return (tlsOptions, pin)
    }

    static func discoverEndpoints(port: UInt16, tls: Bool) -> [String] {
        let scheme = tls ? "wss" : "ws"
        var tailscaleEndpoints: [String] = []
        var lanEndpoints: [String] = []

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr {
            defer { freeifaddrs(ifaddrPtr) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
            while let current = cursor {
                let flags = Int32(current.pointee.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
                if isUp, let addr = current.pointee.ifa_addr {
                    let family = addr.pointee.sa_family
                    if family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            addr,
                            socklen_t(addr.pointee.sa_len),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        ) == 0 {
                            let ip = String(cString: hostname)
                            let endpoint = "\(scheme)://\(ip):\(port)\(MicroRemoteConstants.defaultWebSocketPath)"
                            if Self.isTailscaleIPv4(ip) {
                                tailscaleEndpoints.append(endpoint)
                            } else if !ip.hasPrefix("169.254.") {
                                lanEndpoints.append(endpoint)
                            }
                        }
                    }
                }
                cursor = current.pointee.ifa_next
            }
        }

        var ordered = tailscaleEndpoints + lanEndpoints
        if ordered.isEmpty {
            ordered.append("\(scheme)://127.0.0.1:\(port)\(MicroRemoteConstants.defaultWebSocketPath)")
        }
        return ordered
    }

    private static func isTailscaleIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (parts[1] >= 64 && parts[1] <= 127)
    }
}
