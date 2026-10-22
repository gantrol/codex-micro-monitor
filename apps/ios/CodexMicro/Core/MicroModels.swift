import Foundation

enum ThreadStatus: String, Codable, Sendable {
    case idle
    case running
    case completed
    case waiting
    case question
    case error
    case overloaded
    case unknown
}

enum MicroCommandKind: String, Codable, CaseIterable, Sendable {
    case select = "thread.select"
    case open = "desktop.openThread"
    case model = "settings.setModel"
    case effort = "settings.setEffort"
    case stepEffort = "settings.stepEffort"
    case fast = "settings.setFastMode"
    case plan = "settings.setPlanMode"
    case approve = "approval.accept"
    case decline = "approval.decline"
    case fork = "thread.fork"
    case stop = "turn.stop"
    case sendText = "turn.sendText"
}

struct MicroApprovalItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var kind: MicroRemoteApprovalKind
    var summary: String
    var commandText: String?
    var cwd: String?
    var filePaths: [String]
    var approvalContentHash: String
    var createdAtMs: Int64

    var detailText: String {
        var lines: [String] = []
        if !summary.isEmpty { lines.append(summary) }
        if let cmd = commandText, !cmd.isEmpty, cmd != summary {
            lines.append("命令：\(cmd)")
        }
        if let cwd, !cwd.isEmpty {
            lines.append("目录：\(cwd)")
        }
        if !filePaths.isEmpty {
            lines.append("文件：\n" + filePaths.prefix(8).joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }
}

struct MicroQuestionItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var prompt: String
    var options: [String]
}

struct MicroLatestReply: Codable, Equatable, Sendable {
    var turnID: String?
    var text: String
    var updatedAtMs: Int64
    var isStreaming: Bool
}

struct MicroThread: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var slotIndex: Int?
    var title: String
    var workspaceName: String
    var status: ThreadStatus
    var modelID: String?
    var effort: String?
    var fast: Bool?
    var plan: Bool?
    var hasDraft: Bool
    var hasUnreadCompletion: Bool
    var pendingApprovalCount: Int
    var pendingQuestionCount: Int
    var updatedAtMs: Int64
    var turnID: String?
    var approval: MicroApprovalItem?
    var capabilities: Set<MicroCommandKind>

    var approvalID: String? { approval?.id }
    var approvalSummary: String? { approval?.summary }

    init(
        id: String,
        slotIndex: Int? = nil,
        title: String,
        workspaceName: String = "Codex",
        status: ThreadStatus,
        modelID: String? = nil,
        effort: String? = nil,
        fast: Bool? = nil,
        plan: Bool? = nil,
        hasDraft: Bool = false,
        hasUnreadCompletion: Bool = false,
        pendingApprovalCount: Int = 0,
        pendingQuestionCount: Int = 0,
        updatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        turnID: String? = nil,
        approval: MicroApprovalItem? = nil,
        capabilities: Set<MicroCommandKind> = Set(MicroCommandKind.allCases)
    ) {
        self.id = id
        self.slotIndex = slotIndex
        self.title = title
        self.workspaceName = workspaceName
        self.status = status
        self.modelID = modelID
        self.effort = effort
        self.fast = fast
        self.plan = plan
        self.hasDraft = hasDraft
        self.hasUnreadCompletion = hasUnreadCompletion
        self.pendingApprovalCount = pendingApprovalCount
        self.pendingQuestionCount = pendingQuestionCount
        self.updatedAtMs = updatedAtMs
        self.turnID = turnID
        self.approval = approval
        self.capabilities = capabilities
    }
}

struct MicroModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let efforts: [String]
}

struct MicroQuotaWindow: Codable, Equatable, Sendable {
    let remainingPercent: Double?
    let resetProgressRatio: Double?
    let resetAtMs: Int64?

    init(remainingPercent: Double?, resetProgressRatio: Double? = nil, resetAtMs: Int64? = nil) {
        self.remainingPercent = remainingPercent
        self.resetProgressRatio = resetProgressRatio
        self.resetAtMs = resetAtMs
    }
}

struct MicroQuota: Codable, Equatable, Sendable {
    let fiveHourWindow: MicroQuotaWindow
    let weeklyWindow: MicroQuotaWindow
    let updatedAtMs: Int64?

    var fiveHour: Double? { fiveHourWindow.remainingPercent }
    var weekly: Double? { weeklyWindow.remainingPercent }

    init(
        fiveHourWindow: MicroQuotaWindow,
        weeklyWindow: MicroQuotaWindow,
        updatedAtMs: Int64? = nil
    ) {
        self.fiveHourWindow = fiveHourWindow
        self.weeklyWindow = weeklyWindow
        self.updatedAtMs = updatedAtMs
    }

    init(fiveHour: Double?, weekly: Double?) {
        self.fiveHourWindow = MicroQuotaWindow(remainingPercent: fiveHour)
        self.weeklyWindow = MicroQuotaWindow(remainingPercent: weekly)
        self.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

struct MicroSnapshot: Codable, Equatable, Sendable {
    let hostID: String
    var hostName: String
    var hostPlatform: MicroRemotePlatform
    let hostEpoch: String
    let revision: Int64
    var snapshotUpdatedAtMs: Int64
    var keypadSlotCount: Int
    var selectedThreadID: String?
    var topModelID: String?
    var topEffort: String?
    var topFast: Bool?
    var topPlan: Bool?
    var threads: [MicroThread]
    var totalThreadCount: Int
    let models: [MicroModel]
    let quota: MicroQuota

    init(
        hostID: String,
        hostName: String = "Host",
        hostPlatform: MicroRemotePlatform = .unknown,
        hostEpoch: String,
        revision: Int64,
        snapshotUpdatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        keypadSlotCount: Int = 6,
        selectedThreadID: String? = nil,
        topModelID: String? = nil,
        topEffort: String? = nil,
        topFast: Bool? = nil,
        topPlan: Bool? = nil,
        threads: [MicroThread],
        totalThreadCount: Int? = nil,
        models: [MicroModel],
        quota: MicroQuota
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostPlatform = hostPlatform
        self.hostEpoch = hostEpoch
        self.revision = revision
        self.snapshotUpdatedAtMs = snapshotUpdatedAtMs
        self.keypadSlotCount = keypadSlotCount
        self.selectedThreadID = selectedThreadID
        self.topModelID = topModelID
        self.topEffort = topEffort
        self.topFast = topFast
        self.topPlan = topPlan
        self.threads = threads
        self.totalThreadCount = totalThreadCount ?? threads.count
        self.models = models
        self.quota = quota
    }
}

struct MicroThreadDetail: Codable, Equatable, Sendable {
    let threadID: String
    let revision: Int64
    var activeTurnID: String?
    var status: ThreadStatus
    var canSubmitText: Bool
    var latestReply: MicroLatestReply?
    var approvals: [MicroApprovalItem]
    var pendingQuestions: [MicroQuestionItem]
}

struct MicroThreadsPage: Codable, Equatable, Sendable {
    let revision: Int64
    var threads: [MicroThread]
    var nextCursor: String?
    var totalCount: Int
}

struct MicroSessionLease: Codable, Equatable, Sendable {
    var leaseID: String
    var role: MicroRemoteRole
    var activeWriterDeviceID: String?
    var activeWriterName: String?
    var canTakeover: Bool
}

struct MicroCommand: Codable, Equatable, Sendable {
    let requestID: UUID
    let hostID: String
    let hostEpoch: String
    let controlLeaseID: String
    let threadID: String
    let kind: MicroCommandKind
    let expectedRevision: Int64
    var value: String?
    var secondaryValue: String?
    var turnID: String?
    var approvalID: String?
    var approvalContentHash: String?
    var payloadHash: String
    var createdAtMs: Int64

    init(
        requestID: UUID = UUID(),
        hostID: String,
        hostEpoch: String,
        controlLeaseID: String,
        threadID: String,
        kind: MicroCommandKind,
        expectedRevision: Int64,
        value: String? = nil,
        secondaryValue: String? = nil,
        turnID: String? = nil,
        approvalID: String? = nil,
        approvalContentHash: String? = nil
    ) {
        self.requestID = requestID
        self.hostID = hostID
        self.hostEpoch = hostEpoch
        self.controlLeaseID = controlLeaseID
        self.threadID = threadID
        self.kind = kind
        self.expectedRevision = expectedRevision
        self.value = value
        self.secondaryValue = secondaryValue
        self.turnID = turnID
        self.approvalID = approvalID
        self.approvalContentHash = approvalContentHash
        self.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)

        var fields: [(String, String)] = [("threadID", threadID)]
        if let value {
            switch kind {
            case .model: fields.append(("model", value))
            case .effort: fields.append(("effort", value))
            case .stepEffort: fields.append(("delta", value))
            case .fast, .plan: fields.append(("enabled", value))
            case .sendText: fields.append(("text", value))
            default: break
            }
        }
        if let secondaryValue, kind == .model {
            fields.append(("effort", secondaryValue))
        }
        if let turnID { fields.append(("turnID", turnID)) }
        if let approvalID { fields.append(("approvalRequestID", approvalID)) }
        if let approvalContentHash { fields.append(("approvalContentHash", approvalContentHash)) }
        self.payloadHash = MicroRemoteCrypto.computeCommandPayloadHash(type: kind.rawValue, fields: fields)
    }
}

struct MicroReceipt: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case accepted
        case applied
        case rejected
        case notSent
        case unknown
    }
    let requestID: UUID
    let status: Status
    var reason: String?
    var threadID: String?
}

enum MicroConnection: Equatable, Sendable {
    case demo
    case disconnected
    case connecting
    case syncing
    case ready
    case suspended
    case failed(String)

    var label: String {
        switch self {
        case .demo: return "DEMO"
        case .disconnected: return "离线"
        case .connecting: return "连接中"
        case .syncing: return "同步中"
        case .ready: return "已连接"
        case .suspended: return "已暂停"
        case .failed: return "连接失败"
        }
    }

    var allowsCommands: Bool { self == .demo || self == .ready }
}

enum MicroEvent: Sendable {
    case connection(MicroConnection)
    case lease(MicroSessionLease)
    case snapshot(MicroSnapshot)
    case threadDetail(MicroThreadDetail)
    case threadsPage(MicroThreadsPage)
    case receipt(MicroReceipt)
    case hostCredentialsUpdated(SavedHost)
}

@MainActor
protocol MicroTransport: AnyObject {
    func connect(_ receive: @escaping @MainActor (MicroEvent) -> Void)
    func send(_ command: MicroCommand) async throws
    func query(_ ids: [UUID]) async throws
    func requestThreadDetail(_ threadID: String) async throws
    func requestThreadsList(query: String?, cursor: String?, limit: Int) async throws
    func requestTakeover() async throws
    func disconnect()
}

enum MicroError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
