import CryptoKit
import Foundation
import MicroShared

enum RemoteThreadDetailReader {
    private static let maxReplyLength = 65_536

    static func projectDetail(
        threadID: String,
        peerState: [String: Any]?,
        catalogThread: [String: Any]?,
        activeTurnID: String?,
        canSubmit: Bool,
        runtimeStatus: [String: Any]
    ) -> [String: Any] {
        let requests = peerState?["requests"] as? [[String: Any]] ?? []
        let approvals = extractApprovals(requests)
        let questions = extractQuestions(requests, peerState: peerState, catalogThread: catalogThread)
        let latestReply = extractLatestReply(
            peerState: peerState,
            catalogThread: catalogThread,
            activeTurnID: activeTurnID
        )

        return [
            "threadId": threadID,
            "activeTurnId": activeTurnID ?? JSON.null as Any,
            "canSubmit": canSubmit,
            "runtimeStatus": runtimeStatus,
            "latestReply": latestReply ?? JSON.null as Any,
            "approvals": approvals,
            "pendingQuestions": questions,
        ]
    }

    private static func extractApprovals(_ requests: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for item in requests {
            let method = item["method"] as? String ?? ""
            guard ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method),
                  let id = requestID(item) else {
                continue
            }
            let params = item["params"] as? [String: Any] ?? [:]
            let isCommand = method == "item/commandExecution/requestApproval"
            let kind = isCommand ? "command" : "fileChange"

            let commandText: String? = {
                if let cmd = params["command"] as? String, !cmd.isEmpty { return cmd }
                if let argv = params["command"] as? [String], !argv.isEmpty { return argv.joined(separator: " ") }
                if let parsed = params["parsedCmd"] as? String, !parsed.isEmpty { return parsed }
                return nil
            }()

            let cwd = (params["cwd"] as? String) ?? (params["workingDirectory"] as? String)

            var filePaths: [String] = []
            if let paths = params["filePaths"] as? [String] {
                filePaths.append(contentsOf: paths)
            } else if let changes = params["changes"] as? [[String: Any]] {
                for change in changes {
                    if let path = (change["path"] as? String) ?? (change["filePath"] as? String) {
                        filePaths.append(path)
                    }
                }
            } else if let path = params["path"] as? String {
                filePaths.append(path)
            }

            let summary: String = {
                if let reason = params["reason"] as? String, !reason.isEmpty { return reason }
                if let cmd = commandText, !cmd.isEmpty { return cmd }
                if !filePaths.isEmpty { return filePaths.joined(separator: ", ") }
                return isCommand ? "Command execution approval" : "File change approval"
            }()

            let contentHash = computeApprovalContentHash(
                requestID: id,
                kind: kind,
                commandText: commandText,
                cwd: cwd,
                filePaths: filePaths
            )

            result.append([
                "id": id,
                "kind": kind,
                "method": method,
                "summary": String(summary.prefix(512)),
                "commandText": commandText.map { String($0.prefix(4096)) } ?? JSON.null as Any,
                "cwd": cwd.map { String($0.prefix(1024)) } ?? JSON.null as Any,
                "filePaths": Array(filePaths.prefix(64)),
                "approvalContentHash": contentHash,
                "createdAtMs": nowMs,
                "details": params,
            ])
        }
        return result
    }

    private static func extractQuestions(
        _ requests: [[String: Any]],
        peerState: [String: Any]?,
        catalogThread: [String: Any]?
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for item in requests where (item["method"] as? String) == "item/tool/requestUserInput" {
            guard let id = requestID(item) else { continue }
            let params = item["params"] as? [String: Any] ?? [:]
            let questions = params["questions"] as? [[String: Any]] ?? []
            if questions.isEmpty {
                let prompt = (params["question"] as? String) ?? (params["prompt"] as? String) ?? "User input requested"
                result.append([
                    "id": id,
                    "prompt": String(prompt.prefix(1024)),
                    "options": [] as [String],
                ])
            } else {
                for (idx, q) in questions.enumerated() {
                    let qid = (q["id"] as? String) ?? "\(id):\(idx)"
                    let prompt = (q["question"] as? String) ?? (q["header"] as? String) ?? "User input requested"
                    let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                    result.append([
                        "id": qid,
                        "prompt": String(prompt.prefix(1024)),
                        "options": Array(opts.prefix(16)),
                    ])
                }
            }
        }
        return result
    }

    private static func extractLatestReply(
        peerState: [String: Any]?,
        catalogThread: [String: Any]?,
        activeTurnID: String?
    ) -> [String: Any]? {
        var turns: [[String: Any]] = []
        if let stateTurns = peerState?["turns"] as? [[String: Any]], !stateTurns.isEmpty {
            turns.append(contentsOf: stateTurns)
        } else if let history = peerState?["turnHistory"] as? [String: Any],
                  let data = history["history"] as? [String: Any],
                  let entities = data["entitiesByKey"] as? [String: [String: Any]] {
            let order = (data["keys"] as? [String]) ?? Array(entities.keys).sorted()
            for key in order {
                if let entity = entities[key] {
                    turns.append(entity)
                }
            }
        }
        if turns.isEmpty, let catalogTurns = catalogThread?["turns"] as? [[String: Any]] {
            turns.append(contentsOf: catalogTurns)
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for turn in turns.reversed() {
            let turnID = (turn["turnId"] as? String) ?? (turn["id"] as? String)
            let items = (turn["items"] as? [[String: Any]]) ?? []
            var turnTexts: [String] = []
            for item in items {
                let itemType = item["type"] as? String ?? ""
                let role = item["role"] as? String ?? ""
                let isAgentMessage = ["agentMessage", "AgentMessage", "assistantMessage"].contains(itemType) ||
                    (itemType == "message" && role == "assistant")
                guard isAgentMessage else { continue }
                if let text = extractItemText(item), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turnTexts.append(text)
                }
            }
            if !turnTexts.isEmpty {
                let joined = String(turnTexts.joined(separator: "\n\n").prefix(maxReplyLength))
                let isStreaming = activeTurnID != nil && (turnID == nil || turnID == activeTurnID)
                return [
                    "turnId": turnID ?? JSON.null as Any,
                    "text": joined,
                    "updatedAtMs": nowMs,
                    "isStreaming": isStreaming,
                ]
            }
        }
        return nil
    }

    private static func extractItemText(_ item: [String: Any]) -> String? {
        if let direct = item["text"] as? String, !direct.isEmpty {
            return direct
        }
        if let content = item["content"] as? [[String: Any]] {
            let parts = content.compactMap { part -> String? in
                if let text = part["text"] as? String, !text.isEmpty { return text }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }
        return nil
    }

    private static func requestID(_ request: [String: Any]) -> String? {
        if let id = request["id"] as? String { return id }
        if let id = request["id"] as? NSNumber { return id.stringValue }
        return nil
    }

    static func computeApprovalContentHash(
        requestID: String,
        kind: String,
        commandText: String?,
        cwd: String?,
        filePaths: [String]
    ) -> String {
        let joinedPaths = filePaths.sorted().joined(separator: "\n")
        let canonical = [
            requestID,
            kind,
            commandText ?? "",
            cwd ?? "",
            joinedPaths,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
