import Foundation

@MainActor
final class DemoTransport: MicroTransport {
    private var receive: (@MainActor (MicroEvent) -> Void)?
    private var receipts: [UUID: MicroReceipt] = [:]
    private var revision: Int64 = 1
    private let epoch = UUID().uuidString
    private var latestReplies: [String: MicroLatestReply] = [:]

    private lazy var threads: [MicroThread] = (0..<14).map { index in
        let statuses: [ThreadStatus] = [
            .running, .completed, .idle, .waiting, .question, .overloaded,
            .error, .completed, .waiting, .idle, .completed, .running,
            .idle, .completed,
        ]
        let names = [
            "UIKit 小键盘", "模型切换", "任务面板", "组件设计", "交互提问", "服务过载重试",
            "连接适配", "图标资源", "审批多选", "布局整理", "文档更新", "协议设计",
            "交互细节", "发布准备",
        ]
        let status = statuses[index]
        let threadID = "demo-\(index)"
        let approval: MicroApprovalItem? = status == .waiting ? MicroApprovalItem(
            id: "approval-\(index)",
            kind: index == 3 ? .command : .fileChange,
            summary: index == 3 ? "git status --short" : "修改 MicroViewController.swift",
            commandText: index == 3 ? "git status --short" : nil,
            cwd: "/Users/demo/codex-micro-monitor",
            filePaths: index == 3 ? [] : ["apps/ios/CodexMicro/UI/MicroViewController.swift"],
            approvalContentHash: MicroRemoteCrypto.computeApprovalContentHash(
                requestID: "approval-\(index)",
                kind: index == 3 ? .command : .fileChange,
                commandText: index == 3 ? "git status --short" : nil,
                cwd: "/Users/demo/codex-micro-monitor",
                filePaths: index == 3 ? [] : ["apps/ios/CodexMicro/UI/MicroViewController.swift"]
            ),
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ) : nil

        return MicroThread(
            id: threadID,
            slotIndex: index,
            title: names[index],
            workspaceName: "codex-micro-monitor",
            status: status,
            modelID: index.isMultiple(of: 2) ? "gpt-5.4" : "gpt-5.4-mini",
            effort: "high",
            fast: false,
            plan: index == 2,
            hasDraft: index == 2 || index == 9,
            hasUnreadCompletion: status == .completed,
            pendingApprovalCount: approval != nil ? (index == 8 ? 2 : 1) : 0,
            pendingQuestionCount: status == .question ? 1 : 0,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000) - Int64(index * 45_000),
            turnID: (status == .running || status == .waiting || status == .question) ? "turn-\(index)" : nil,
            approval: approval,
            capabilities: Set(MicroCommandKind.allCases)
        )
    }

    func connect(_ receive: @escaping @MainActor (MicroEvent) -> Void) {
        self.receive = receive
        receive(.lease(MicroSessionLease(
            leaseID: "demo-lease",
            role: .readWrite,
            activeWriterDeviceID: "demo-device",
            activeWriterName: "iPhone",
            canTakeover: true
        )))
        publish()
        receive(.connection(.demo))
    }

    func send(_ command: MicroCommand) async throws {
        guard let index = threads.firstIndex(where: { $0.id == command.threadID }) else { return }
        if let receipt = receipts[command.requestID] {
            receive?(.receipt(receipt))
            return
        }
        receive?(.receipt(MicroReceipt(requestID: command.requestID, status: .accepted, threadID: command.threadID)))

        switch command.kind {
        case .select, .open:
            break
        case .fast:
            threads[index].fast = (command.value == "true")
        case .plan:
            threads[index].plan = (command.value == "true")
        case .model:
            threads[index].modelID = command.value ?? threads[index].modelID
            if let eff = command.secondaryValue {
                threads[index].effort = eff
            }
        case .effort:
            threads[index].effort = command.value ?? threads[index].effort
        case .stepEffort:
            let efforts = ["low", "medium", "high", "xhigh"]
            let delta = Int(command.value ?? "1") ?? 1
            let cur = efforts.firstIndex(of: threads[index].effort ?? "high") ?? 2
            threads[index].effort = efforts[min(max(0, cur + delta), efforts.count - 1)]
        case .approve, .decline:
            threads[index].approval = nil
            threads[index].pendingApprovalCount = 0
            threads[index].status = command.kind == .approve ? .running : .idle
            threads[index].turnID = command.kind == .approve ? UUID().uuidString : nil
        case .stop:
            threads[index].status = .idle
            threads[index].turnID = nil
        case .sendText:
            let text = command.value ?? ""
            threads[index].status = .running
            let turnID = "turn-" + UUID().uuidString.prefix(8)
            threads[index].turnID = String(turnID)
            latestReplies[command.threadID] = MicroLatestReply(
                turnID: String(turnID),
                text: "已收到指令：\(text)\n正在执行任务并同步状态。",
                updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                isStreaming: true
            )
        case .fork:
            var copy = threads[index]
            copy = MicroThread(
                id: UUID().uuidString,
                slotIndex: 0,
                title: copy.title + " · 分叉",
                workspaceName: copy.workspaceName,
                status: .idle,
                modelID: copy.modelID,
                effort: copy.effort,
                fast: copy.fast,
                plan: copy.plan,
                capabilities: copy.capabilities
            )
            threads.insert(copy, at: 0)
        }

        revision += 1
        let receipt = MicroReceipt(requestID: command.requestID, status: .applied, threadID: command.threadID)
        receipts[command.requestID] = receipt
        publish()
        receive?(.receipt(receipt))
    }

    func query(_ ids: [UUID]) async throws {
        for id in ids {
            receive?(.receipt(receipts[id] ?? MicroReceipt(requestID: id, status: .unknown)))
        }
    }

    func requestThreadDetail(_ threadID: String) async throws {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
        var approvals: [MicroApprovalItem] = []
        if let primary = thread.approval {
            approvals.append(primary)
            if thread.pendingApprovalCount > 1 {
                let secondID = primary.id + "-b"
                approvals.append(MicroApprovalItem(
                    id: secondID,
                    kind: .command,
                    summary: "swift build --package-path apps/macos",
                    commandText: "swift build --package-path apps/macos",
                    cwd: "/Users/demo/codex-micro-monitor",
                    filePaths: [],
                    approvalContentHash: MicroRemoteCrypto.computeApprovalContentHash(
                        requestID: secondID,
                        kind: .command,
                        commandText: "swift build --package-path apps/macos",
                        cwd: "/Users/demo/codex-micro-monitor",
                        filePaths: []
                    ),
                    createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
                ))
            }
        }

        let questions: [MicroQuestionItem] = thread.status == .question ? [
            MicroQuestionItem(
                id: "q-1",
                prompt: "请选择外网连接优先方案：",
                options: ["方案 A：Tailscale 组网直连", "方案 B：Micro 自建 E2EE 中继"]
            ),
        ] : []

        let reply = latestReplies[threadID] ?? MicroLatestReply(
            turnID: thread.turnID,
            text: "已完成「\(thread.title)」的状态检查与代码同步。当前线程状态：\(MicroTheme.statusName(thread.status))。",
            updatedAtMs: thread.updatedAtMs,
            isStreaming: thread.status == .running
        )

        receive?(.threadDetail(MicroThreadDetail(
            threadID: threadID,
            revision: revision,
            activeTurnID: thread.turnID,
            status: thread.status,
            canSubmitText: thread.status == .idle && approvals.isEmpty && questions.isEmpty,
            latestReply: reply,
            approvals: approvals,
            pendingQuestions: questions
        )))
    }

    func requestThreadsList(query: String?, cursor: String?, limit: Int) async throws {
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let filtered = threads.filter { t in
            guard !q.isEmpty else { return true }
            return t.title.lowercased().contains(q) || t.workspaceName.lowercased().contains(q)
        }
        let offset = Int(cursor ?? "0") ?? 0
        let start = min(offset, filtered.count)
        let end = min(start + max(1, limit), filtered.count)
        let slice = Array(filtered[start..<end])
        let next = end < filtered.count ? String(end) : nil
        receive?(.threadsPage(MicroThreadsPage(
            revision: revision,
            threads: slice,
            nextCursor: next,
            totalCount: filtered.count
        )))
    }

    func requestTakeover() async throws {
        receive?(.lease(MicroSessionLease(
            leaseID: "demo-lease",
            role: .readWrite,
            activeWriterDeviceID: "demo-device",
            activeWriterName: "iPhone",
            canTakeover: true
        )))
    }

    func disconnect() {
        receive = nil
    }

    private func publish() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        receive?(.snapshot(MicroSnapshot(
            hostID: "demo",
            hostName: "Demo Mac Studio",
            hostPlatform: .macos,
            hostEpoch: epoch,
            revision: revision,
            snapshotUpdatedAtMs: nowMs,
            keypadSlotCount: 14,
            selectedThreadID: threads.first?.id,
            threads: threads,
            totalThreadCount: threads.count,
            models: [
                MicroModel(id: "gpt-5.4", name: "GPT-5.4", efforts: ["low", "medium", "high", "xhigh"]),
                MicroModel(id: "gpt-5.4-mini", name: "GPT-5.4-MINI", efforts: ["low", "medium", "high"]),
            ],
            quota: MicroQuota(
                fiveHourWindow: MicroQuotaWindow(remainingPercent: 77, resetProgressRatio: 0.62, resetAtMs: nowMs + 6_800_000),
                weeklyWindow: MicroQuotaWindow(remainingPercent: 58, resetProgressRatio: 0.45, resetAtMs: nowMs + 280_000_000),
                updatedAtMs: nowMs
            )
        )))
    }
}
