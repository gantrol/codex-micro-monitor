import Foundation

@MainActor
final class WebSocketTransport: MicroTransport {
    private var host: SavedHost
    private let identity: ClientDeviceIdentity
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var handshake: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var receive: (@MainActor (MicroEvent) -> Void)?
    private var generation = UUID()
    private var epoch = UUID().uuidString
    private var synchronized = false
    private var isRevokedOrPermanentAuthFailure = false
    private var reconnectAttempt = 0
    private var outboundSeq: UInt64 = 0
    private var relaySessionID = "relay-" + UUID().uuidString.lowercased()

    init(credentials: SavedHost) {
        self.host = credentials
        self.identity = HostKeychain.deviceIdentity()
    }

    func connect(_ receive: @escaping @MainActor (MicroEvent) -> Void) {
        disconnect(clearReceive: false)
        self.receive = receive
        self.isRevokedOrPermanentAuthFailure = false
        self.reconnectAttempt = 0
        startConnectionAttempt()
    }

    private func startConnectionAttempt() {
        guard let receive else { return }
        receive(.connection(.connecting))
        do {
            let candidateURLs = try host.validatedCandidateURLs()
            let baseURL = candidateURLs[reconnectAttempt % candidateURLs.count]
            let targetURL = try buildWebSocketURL(from: baseURL)

            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 12
            configuration.httpCookieStorage = nil

            let pin = (host.mode == .directTailscale) ? host.normalizedPin : ""
            let delegate = HostTrustDelegate(host: targetURL.host ?? "", pin: pin)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: targetURL)
            if host.mode == .directTailscale && !host.isPairingToken {
                request.setValue("Bearer \(host.token)", forHTTPHeaderField: "Authorization")
            }

            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 1_048_576
            self.socket = socket

            let token = UUID()
            self.generation = token
            self.synchronized = false
            socket.resume()

            reader = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.performInitialHandshake()
                    while !Task.isCancelled && self.generation == token {
                        let message = try await socket.receive()
                        guard self.generation == token else { return }
                        let rawText: String
                        switch message {
                        case .string(let s): rawText = s
                        case .data(let d): rawText = String(decoding: d, as: UTF8.self)
                        @unknown default: throw MicroError.message("不支持的 Host 消息")
                        }
                        try await self.handleIncomingFrameText(rawText)
                    }
                } catch {
                    if self.generation == token && !Task.isCancelled {
                        self.handleConnectionFailure(error.localizedDescription)
                    }
                }
            }

            handshake = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token, !self.synchronized else { return }
                self.handleConnectionFailure("Host 同步超时")
            }
        } catch {
            handleConnectionFailure(error.localizedDescription)
        }
    }

    private func buildWebSocketURL(from baseURL: URL) throws -> URL {
        guard host.mode == .relayE2EE else { return baseURL }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MicroError.message("中继地址格式无效")
        }
        var items = components.queryItems ?? []
        items.removeAll { ["role", "hostId", "deviceId"].contains($0.name) }
        items.append(URLQueryItem(name: "role", value: "device"))
        items.append(URLQueryItem(name: "hostId", value: host.id))
        items.append(URLQueryItem(name: "deviceId", value: identity.deviceID))
        components.queryItems = items
        guard let url = components.url else {
            throw MicroError.message("中继地址格式无效")
        }
        return url
    }

    private func performInitialHandshake() async throws {
        if host.isPairingToken {
            try await sendProtocolEnvelope(
                type: "pair.exchange",
                requestID: UUID().uuidString,
                payload: [
                    "pairingToken": host.token,
                    "deviceID": identity.deviceID,
                    "deviceName": identity.deviceName,
                    "platform": "ios",
                    "devicePublicKey": identity.publicKeyBase64,
                ]
            )
        } else {
            try await sendHello()
        }
    }

    private func sendHello() async throws {
        try await sendProtocolEnvelope(
            type: "hello",
            requestID: UUID().uuidString,
            payload: [
                "protocolVersion": MicroRemoteConstants.protocolVersion,
                "minSupportedVersion": MicroRemoteConstants.minSupportedVersion,
                "deviceID": identity.deviceID,
                "deviceName": identity.deviceName,
                "deviceToken": host.token,
                "devicePublicKey": identity.publicKeyBase64,
                "clientPlatform": "ios",
            ]
        )
    }

    func send(_ command: MicroCommand) async throws {
        guard synchronized else {
            receive?(.receipt(MicroReceipt(
                requestID: command.requestID,
                status: .notSent,
                reason: "连接状态已变化",
                threadID: command.threadID
            )))
            return
        }

        var payload: [String: Any] = [
            "threadID": command.threadID,
            "payloadHash": command.payloadHash,
        ]
        switch command.kind {
        case .select:
            payload["openInDesktop"] = false
        case .open:
            payload["openInDesktop"] = true
        case .model:
            payload["model"] = command.value ?? ""
            if let effort = command.secondaryValue, !effort.isEmpty {
                payload["effort"] = effort
            }
        case .effort:
            payload["effort"] = command.value ?? ""
        case .stepEffort:
            payload["delta"] = Int(command.value ?? "1") ?? 1
        case .fast, .plan:
            payload["enabled"] = (command.value == "true")
        case .approve, .decline:
            payload["approvalRequestID"] = command.approvalID ?? ""
            if let hash = command.approvalContentHash, !hash.isEmpty {
                payload["approvalContentHash"] = hash
            }
        case .stop:
            payload["turnID"] = command.turnID ?? ""
        case .sendText:
            payload["text"] = command.value ?? ""
        case .fork:
            break
        }

        let wireType = (command.kind == .open) ? "thread.select" : command.kind.rawValue
        try await sendProtocolEnvelope(
            type: wireType,
            requestID: command.requestID.uuidString,
            payload: payload
        )
    }

    func query(_ ids: [UUID]) async throws {
        guard synchronized, !ids.isEmpty else { return }
        for id in ids {
            try await sendProtocolEnvelope(
                type: "command.queryResult",
                requestID: id.uuidString,
                payload: ["targetRequestID": id.uuidString]
            )
        }
    }

    func requestThreadDetail(_ threadID: String) async throws {
        guard synchronized, !threadID.isEmpty else { return }
        try await sendProtocolEnvelope(
            type: "thread.detail.read",
            requestID: UUID().uuidString,
            payload: ["threadID": threadID]
        )
    }

    func requestThreadsList(query: String?, cursor: String?, limit: Int = 30) async throws {
        guard synchronized else { return }
        var payload: [String: Any] = ["limit": limit]
        if let query, !query.isEmpty { payload["query"] = query }
        if let cursor, !cursor.isEmpty { payload["cursor"] = cursor }
        try await sendProtocolEnvelope(
            type: "threads.list",
            requestID: UUID().uuidString,
            payload: payload
        )
    }

    func requestTakeover() async throws {
        guard synchronized else { return }
        try await sendProtocolEnvelope(
            type: "session.takeover",
            requestID: UUID().uuidString,
            payload: ["reason": "user_requested_takeover"]
        )
    }

    private func handleIncomingFrameText(_ rawText: String) async throws {
        guard let rawData = rawText.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let outerType = outer["type"] as? String else {
            return
        }

        if outerType == "relay.envelope" {
            guard let envelope = try? JSONDecoder().decode(MicroRelayEnvelope.self, from: rawData) else {
                return
            }
            if host.hostPublicKey == nil || host.hostPublicKey?.isEmpty == true {
                host.hostPublicKey = envelope.senderPublicKey
            }
            let decrypted = try MicroRemoteCrypto.openRelayEnvelope(
                envelope,
                recipientPrivateKeyBase64: identity.privateKeyBase64
            )
            guard let innerText = String(data: decrypted, encoding: .utf8) else { return }
            try await handleProtocolMessage(innerText)
            return
        }

        if outerType == "relay.hostOffline" {
            throw MicroError.message("电脑端 Host 当前不在线")
        }
        if outerType == "relay.hostOnline" {
            try await performInitialHandshake()
            return
        }

        try await handleProtocolMessage(rawText)
    }

    private func handleProtocolMessage(_ text: String) async throws {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }
        let requestIDString = obj["requestID"] as? String
        let payload = obj["payload"] as? [String: Any] ?? [:]

        switch type {
        case "pair.accepted":
            guard let deviceToken = payload["deviceToken"] as? String, !deviceToken.isEmpty else {
                throw MicroError.message("配对响应缺少设备令牌")
            }
            if let hostID = payload["hostID"] as? String, !hostID.isEmpty {
                host.id = hostID
            }
            if let hostName = payload["hostName"] as? String, !hostName.isEmpty {
                host.name = hostName
            }
            if let platformRaw = payload["hostPlatform"] as? String,
               let platform = MicroRemotePlatform(rawValue: platformRaw) {
                host.platform = platform
            }
            if let pubKey = payload["hostPublicKey"] as? String, !pubKey.isEmpty {
                host.hostPublicKey = pubKey
            }
            if let pin = payload["certPinSHA256"] as? String, !pin.isEmpty {
                host.certificateSHA256 = pin
            }
            if let endpoints = payload["endpoints"] as? [String], !endpoints.isEmpty {
                host.endpoints = endpoints
            }
            host.token = deviceToken
            host.isPairingToken = false
            host.lastConnectedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            try? HostKeychain.upsertHost(host)
            receive?(.hostCredentialsUpdated(host))
            try await sendHello()

        case "hello.ok":
            if let hostID = payload["hostID"] as? String, !hostID.isEmpty {
                host.id = hostID
            }
            if let hostName = payload["hostName"] as? String, !hostName.isEmpty {
                host.name = hostName
            }
            if let platformRaw = payload["hostPlatform"] as? String,
               let platform = MicroRemotePlatform(rawValue: platformRaw) {
                host.platform = platform
            }
            let roleRaw = (payload["role"] as? String) ?? "readWrite"
            let role = MicroRemoteRole(rawValue: roleRaw) ?? .readWrite
            let writerID = payload["activeWriterDeviceID"] as? String
            let writerName = payload["activeWriterName"] as? String
            let canTakeover = (payload["canTakeover"] as? Bool) ?? true

            let lease = MicroSessionLease(
                leaseID: "lease-\(host.id)-\(role.rawValue)",
                role: role,
                activeWriterDeviceID: writerID,
                activeWriterName: writerName,
                canTakeover: canTakeover
            )
            receive?(.lease(lease))
            receive?(.connection(.syncing))
            startHeartbeat()

        case "session.lease":
            let roleRaw = (payload["role"] as? String) ?? "readOnly"
            let role = MicroRemoteRole(rawValue: roleRaw) ?? .readOnly
            let writerID = payload["activeWriterDeviceID"] as? String
            let writerName = payload["activeWriterName"] as? String
            let canTakeover = (payload["canTakeover"] as? Bool) ?? true
            receive?(.lease(MicroSessionLease(
                leaseID: "lease-\(host.id)-\(role.rawValue)",
                role: role,
                activeWriterDeviceID: writerID,
                activeWriterName: writerName,
                canTakeover: canTakeover
            )))

        case "auth.revoked":
            isRevokedOrPermanentAuthFailure = true
            let reason = (payload["reason"] as? String) ?? "设备权限已在电脑端吊销"
            throw MicroError.message(reason)

        case "state.snapshot":
            let snap = try parseSnapshotPayload(payload, fallbackObj: obj)
            receive?(.snapshot(snap))
            synchronized = true
            reconnectAttempt = 0
            handshake?.cancel()
            receive?(.connection(.ready))

        case "threads.list.result":
            let page = parseThreadsListPayload(payload)
            receive?(.threadsPage(page))

        case "thread.detail.result":
            if let detail = parseThreadDetailPayload(payload) {
                receive?(.threadDetail(detail))
            }

        case "command.ack":
            guard let reqIDStr = requestIDString,
                  let reqUUID = UUID(uuidString: reqIDStr) else {
                return
            }
            let statusRaw = (payload["status"] as? String) ?? "unknown"
            let receiptStatus: MicroReceipt.Status = switch statusRaw {
            case "completed": .applied
            case "in_progress": .accepted
            case "rejected": .rejected
            default: .unknown
            }
            let message = (payload["message"] as? String) ?? (payload["errorCode"] as? String)
            let threadID = payload["threadID"] as? String
            receive?(.receipt(MicroReceipt(
                requestID: reqUUID,
                status: receiptStatus,
                reason: message,
                threadID: threadID
            )))

        case "pong":
            break

        case "error":
            let code = (payload["code"] as? String) ?? ""
            let msg = (payload["message"] as? String) ?? (obj["reason"] as? String) ?? "Host 拒绝操作"
            if ["auth_failed", "invalid_pairing_token", "unauthorized"].contains(code) && !synchronized {
                isRevokedOrPermanentAuthFailure = true
                throw MicroError.message(msg)
            }
            if let reqIDStr = requestIDString, let reqUUID = UUID(uuidString: reqIDStr) {
                receive?(.receipt(MicroReceipt(
                    requestID: reqUUID,
                    status: .rejected,
                    reason: msg
                )))
            } else if !synchronized {
                throw MicroError.message(msg)
            }

        default:
            break
        }
    }

    private func parseSnapshotPayload(_ payload: [String: Any], fallbackObj: [String: Any]) throws -> MicroSnapshot {
        let source = payload.isEmpty ? (fallbackObj["snapshot"] as? [String: Any] ?? [:]) : payload
        let rev = (source["revision"] as? NSNumber)?.int64Value ?? 1
        let snapHostID = (source["hostID"] as? String) ?? host.id
        let snapHostName = (source["hostName"] as? String) ?? host.name
        let snapPlatform = (source["hostPlatform"] as? String).flatMap(MicroRemotePlatform.init(rawValue:)) ?? host.platform
        let updatedAtMs = (source["snapshotUpdatedAtMs"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
        let slotCount = (source["keypadSlotCount"] as? Int) ?? 6
        let selectedThreadID = source["selectedThreadID"] as? String
        let topModel = source["model"] as? String
        let topEffort = source["effort"] as? String
        let topFast = source["fastMode"] as? Bool
        let topPlan = source["planMode"] as? Bool

        var parsedModels: [MicroModel] = []
        if let catalog = source["modelCatalog"] as? [String: Any],
           let names = catalog["models"] as? [String] {
            let effortsMap = catalog["effortsByModel"] as? [String: [String]] ?? [:]
            for modelID in names where !modelID.isEmpty {
                let efforts = effortsMap[modelID] ?? ["low", "medium", "high"]
                parsedModels.append(MicroModel(
                    id: modelID,
                    name: modelID.uppercased(),
                    efforts: efforts.isEmpty ? ["medium"] : efforts
                ))
            }
        } else if let legacyModels = source["models"] as? [[String: Any]] {
            for item in legacyModels {
                guard let id = item["id"] as? String else { continue }
                let name = (item["name"] as? String) ?? id
                let efforts = (item["efforts"] as? [String]) ?? ["low", "medium", "high"]
                parsedModels.append(MicroModel(id: id, name: name, efforts: efforts))
            }
        }

        let rawThreads = (source["threads"] as? [[String: Any]]) ?? []
        let threads = rawThreads.map { item -> MicroThread in
            Self.parseThreadItem(
                item,
                fallbackModel: topModel,
                fallbackEffort: topEffort,
                fallbackFast: topFast,
                fallbackPlan: topPlan
            )
        }

        let quotaRaw = (source["quota"] as? [String: Any]) ?? [:]
        let quota = Self.parseQuota(quotaRaw)
        let totalCount = (source["totalThreadCount"] as? Int) ?? threads.count

        return MicroSnapshot(
            hostID: snapHostID,
            hostName: snapHostName,
            hostPlatform: snapPlatform,
            hostEpoch: epoch,
            revision: rev,
            snapshotUpdatedAtMs: updatedAtMs,
            keypadSlotCount: slotCount,
            selectedThreadID: selectedThreadID,
            topModelID: topModel,
            topEffort: topEffort,
            topFast: topFast,
            topPlan: topPlan,
            threads: threads,
            totalThreadCount: totalCount,
            models: parsedModels,
            quota: quota
        )
    }

    private func parseThreadsListPayload(_ payload: [String: Any]) -> MicroThreadsPage {
        let rev = (payload["revision"] as? NSNumber)?.int64Value ?? 1
        let rawThreads = (payload["threads"] as? [[String: Any]]) ?? []
        let threads = rawThreads.map { Self.parseThreadItem($0, fallbackModel: nil, fallbackEffort: nil, fallbackFast: nil, fallbackPlan: nil) }
        let nextCursor = payload["nextCursor"] as? String
        let totalCount = (payload["totalCount"] as? Int) ?? threads.count
        return MicroThreadsPage(revision: rev, threads: threads, nextCursor: nextCursor, totalCount: totalCount)
    }

    private func parseThreadDetailPayload(_ payload: [String: Any]) -> MicroThreadDetail? {
        guard let threadID = payload["threadID"] as? String, !threadID.isEmpty else { return nil }
        let rev = (payload["revision"] as? NSNumber)?.int64Value ?? 1
        let activeTurnID = payload["activeTurnID"] as? String
        let statusRaw = (payload["status"] as? String) ?? "idle"
        let status = ThreadStatus(rawValue: statusRaw) ?? .unknown
        let canSubmitText = (payload["canSubmitText"] as? Bool) ?? false

        var latestReply: MicroLatestReply?
        if let replyRaw = payload["latestReply"] as? [String: Any],
           let text = replyRaw["text"] as? String {
            latestReply = MicroLatestReply(
                turnID: (replyRaw["turnID"] as? String) ?? (replyRaw["turnId"] as? String),
                text: text,
                updatedAtMs: (replyRaw["updatedAtMs"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000),
                isStreaming: (replyRaw["isStreaming"] as? Bool) ?? false
            )
        }

        let approvalsRaw = (payload["approvals"] as? [[String: Any]]) ?? []
        let approvals = approvalsRaw.compactMap { Self.parseApprovalItem($0) }

        let questionsRaw = (payload["pendingQuestions"] as? [[String: Any]]) ?? []
        let questions = questionsRaw.compactMap { q -> MicroQuestionItem? in
            guard let id = q["id"] as? String else { return nil }
            let prompt = (q["prompt"] as? String) ?? "等待输入"
            let options = (q["options"] as? [String]) ?? []
            return MicroQuestionItem(id: id, prompt: prompt, options: options)
        }

        return MicroThreadDetail(
            threadID: threadID,
            revision: rev,
            activeTurnID: activeTurnID,
            status: status,
            canSubmitText: canSubmitText,
            latestReply: latestReply,
            approvals: approvals,
            pendingQuestions: questions
        )
    }

    private static func parseThreadItem(
        _ item: [String: Any],
        fallbackModel: String?,
        fallbackEffort: String?,
        fallbackFast: Bool?,
        fallbackPlan: Bool?
    ) -> MicroThread {
        let id = (item["id"] as? String) ?? UUID().uuidString
        let slotIndex = item["slotIndex"] as? Int
        let title = (item["title"] as? String) ?? "未命名会话"
        let workspaceName = (item["workspaceName"] as? String) ?? "Codex"
        let statusRaw = (item["status"] as? String) ?? "idle"
        let status = ThreadStatus(rawValue: statusRaw) ?? .unknown

        let modelID = (item["model"] as? String) ?? (item["modelID"] as? String) ?? fallbackModel
        let effort = (item["effort"] as? String) ?? fallbackEffort
        let fast = (item["fastMode"] as? Bool) ?? (item["fast"] as? Bool) ?? fallbackFast
        let plan = (item["planMode"] as? Bool) ?? (item["plan"] as? Bool) ?? fallbackPlan

        let hasDraft = (item["hasDraft"] as? Bool) ?? false
        let hasUnread = (item["hasUnreadCompletion"] as? Bool) ?? (status == .completed)
        let turnID = (item["activeTurnID"] as? String) ?? (item["turnID"] as? String)
        let updatedAtMs = (item["updatedAtMs"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)

        var approval: MicroApprovalItem?
        if let appRaw = item["pendingApproval"] as? [String: Any] {
            approval = parseApprovalItem(appRaw)
        } else if let legacyAppID = item["approvalID"] as? String {
            let summary = (item["approvalSummary"] as? String) ?? "待审批操作"
            approval = MicroApprovalItem(
                id: legacyAppID,
                kind: .other,
                summary: summary,
                commandText: summary,
                cwd: nil,
                filePaths: [],
                approvalContentHash: MicroRemoteCrypto.computeApprovalContentHash(
                    requestID: legacyAppID,
                    kind: .other,
                    commandText: summary,
                    cwd: nil,
                    filePaths: []
                ),
                createdAtMs: updatedAtMs
            )
        }

        let approvalCount = (item["pendingApprovalCount"] as? Int) ?? (approval != nil ? 1 : 0)
        let questionCount = (item["pendingQuestionCount"] as? Int) ?? (status == .question ? 1 : 0)

        return MicroThread(
            id: id,
            slotIndex: slotIndex,
            title: title,
            workspaceName: workspaceName,
            status: status,
            modelID: modelID,
            effort: effort,
            fast: fast,
            plan: plan,
            hasDraft: hasDraft,
            hasUnreadCompletion: hasUnread,
            pendingApprovalCount: approvalCount,
            pendingQuestionCount: questionCount,
            updatedAtMs: updatedAtMs,
            turnID: turnID,
            approval: approval,
            capabilities: Set(MicroCommandKind.allCases)
        )
    }

    private static func parseApprovalItem(_ raw: [String: Any]) -> MicroApprovalItem? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        let kindRaw = (raw["kind"] as? String) ?? "other"
        let kind = MicroRemoteApprovalKind(rawValue: kindRaw) ?? .other
        let summary = (raw["summary"] as? String) ?? "待审批请求"
        let cmd = raw["commandText"] as? String
        let cwd = raw["cwd"] as? String
        let paths = (raw["filePaths"] as? [String]) ?? []
        let hash = (raw["approvalContentHash"] as? String) ?? MicroRemoteCrypto.computeApprovalContentHash(
            requestID: id,
            kind: kind,
            commandText: cmd,
            cwd: cwd,
            filePaths: paths
        )
        let createdAtMs = (raw["createdAtMs"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
        return MicroApprovalItem(
            id: id,
            kind: kind,
            summary: summary,
            commandText: cmd,
            cwd: cwd,
            filePaths: paths,
            approvalContentHash: hash,
            createdAtMs: createdAtMs
        )
    }

    private static func parseQuota(_ raw: [String: Any]) -> MicroQuota {
        func parseWindow(_ winObj: Any?, legacyPercent: Any?) -> MicroQuotaWindow {
            if let dict = winObj as? [String: Any] {
                let ratio = (dict["remainingRatio"] as? NSNumber)?.doubleValue
                let percent = ratio.map { $0 <= 1.0 ? ($0 * 100.0) : $0 }
                let resetProgress = (dict["resetProgressRatio"] as? NSNumber)?.doubleValue
                let resetAtMs = (dict["resetAtMs"] as? NSNumber)?.int64Value
                return MicroQuotaWindow(
                    remainingPercent: percent,
                    resetProgressRatio: resetProgress,
                    resetAtMs: resetAtMs
                )
            }
            if let num = (legacyPercent as? NSNumber)?.doubleValue {
                return MicroQuotaWindow(remainingPercent: num)
            }
            return MicroQuotaWindow(remainingPercent: nil)
        }

        let fiveHour = parseWindow(raw["fiveHour"], legacyPercent: raw["fiveHour"])
        let sevenDay = parseWindow(raw["sevenDay"], legacyPercent: raw["weekly"])
        let updatedAtMs = (raw["updatedAtMs"] as? NSNumber)?.int64Value
        return MicroQuota(fiveHourWindow: fiveHour, weeklyWindow: sevenDay, updatedAtMs: updatedAtMs)
    }

    private func sendProtocolEnvelope(
        type: String,
        requestID: String?,
        payload: [String: Any]
    ) async throws {
        guard let socket else { throw MicroError.message("Host 未连接") }
        var dict: [String: Any] = [
            "type": type,
            "v": MicroRemoteConstants.protocolVersion,
            "payload": payload,
        ]
        if let requestID {
            dict["requestID"] = requestID
        }
        let plainData = try JSONSerialization.data(withJSONObject: dict)

        if host.mode == .relayE2EE {
            guard let hostPubKey = host.hostPublicKey, !hostPubKey.isEmpty else {
                throw MicroError.message("缺少 Host 公钥，请重新扫码配对")
            }
            outboundSeq += 1
            let sealed = try MicroRemoteCrypto.sealRelayEnvelope(
                plaintext: plainData,
                sessionID: relaySessionID,
                hostID: host.id,
                deviceID: identity.deviceID,
                seq: outboundSeq,
                senderPrivateKeyBase64: identity.privateKeyBase64,
                recipientPublicKeyBase64: hostPubKey
            )
            let envData = try JSONEncoder().encode(sealed)
            try await socket.send(.string(String(decoding: envData, as: UTF8.self)))
        } else {
            try await socket.send(.string(String(decoding: plainData, as: UTF8.self)))
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let token = generation
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                do {
                    try await self.sendProtocolEnvelope(
                        type: "ping",
                        requestID: UUID().uuidString,
                        payload: ["clientTimestampMs": Int64(Date().timeIntervalSince1970 * 1000)]
                    )
                } catch {
                    self.handleConnectionFailure(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handleConnectionFailure(_ reason: String) {
        let callback = receive
        cleanupCurrentSocket()
        callback?(.connection(.failed(reason)))

        guard !isRevokedOrPermanentAuthFailure, receive != nil else { return }
        reconnectAttempt += 1
        let baseDelay = min(15.0, pow(2.0, Double(min(reconnectAttempt - 1, 4))))
        let jitter = Double.random(in: 0.0...0.6)
        let delayNs = UInt64((baseDelay + jitter) * 1_000_000_000)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, let self, self.receive != nil else { return }
            self.startConnectionAttempt()
        }
    }

    private func cleanupCurrentSocket() {
        generation = UUID()
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        handshake?.cancel(); handshake = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        synchronized = false
    }

    func disconnect() {
        disconnect(clearReceive: true)
    }

    private func disconnect(clearReceive: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        cleanupCurrentSocket()
        if clearReceive {
            receive = nil
        }
    }
}
