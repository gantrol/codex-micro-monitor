import Foundation

/// Resolves command authority once. A displayed client-to-thread binding never
/// upgrades a native composer into a server mutation target.
struct PreparedControlCommand {
    let operation: String
    let arguments: [String: Any]
    let target: ControlTarget

    init(_ operation: String, target: ControlTarget, arguments: [String: Any]) throws {
        self.target = target
        var parameters = arguments
        if target.usesNativeSettings {
            let nativeOperations = [
                "set_keypad_model": "set_keypad_draft_model",
                "set_keypad_reasoning": "set_keypad_draft_reasoning",
                "set_keypad_fast": "set_keypad_draft_fast",
                "toggle_keypad_plan": "toggle_keypad_draft_plan"
            ]
            guard let mapped = nativeOperations[operation], let token = target.uiToken, !token.isEmpty else {
                throw CommandExecutor.targetChanged()
            }
            self.operation = mapped
            parameters["thread_id"] = nil
            parameters["target_token"] = token
            parameters["native_composer"] = target.isNativeComposer
        } else {
            guard UUID(uuidString: target.threadID) != nil else { throw CommandExecutor.targetChanged() }
            self.operation = operation
            parameters["thread_id"] = target.threadID
            parameters["target_token"] = nil
            parameters["native_composer"] = nil
        }
        self.arguments = parameters
    }
}

/// Owns preflight and dispatch, never presentation state. Each asynchronous
/// boundary must retain the caller's lifecycle/selection authority. Mutations
/// are sent once; an unknown outcome is reconciled by a separate read.
@MainActor final class CommandExecutor {
    private let client: DesktopControlling
    init(client: DesktopControlling) { self.client = client }

    nonisolated static func targetChanged(_ reason: String? = nil) -> NSError {
        NSError(domain: "MicroBridge", code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason ?? tr("targetChanged")])
    }

    func execute(_ command: PreparedControlCommand,
                 isCurrent: () -> Bool) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard isCurrent() else { throw Self.targetChanged() }
        let target = command.target
        if !target.usesNativeSettings, target.contextSource != "selected" {
            let observed = try await client.execute("get_keypad_ui_state", arguments: [:])
            try Task.checkCancellation()
            guard isCurrent() else { throw Self.targetChanged() }
            guard observed["available"] as? Bool == true,
                  observed["threadId"] as? String == target.threadID,
                  observed["draft"] as? Bool != true,
                  observed["routeReadOnly"] as? Bool != true else {
                throw Self.targetChanged(observed["reason"] as? String)
            }
        }
        // The backend independently verifies the native lease or exact server
        // owner and input deadline immediately before applying the operation.
        let result = try await client.execute(command.operation, arguments: command.arguments)
        try Task.checkCancellation()
        guard isCurrent() else { throw Self.targetChanged() }
        return result
    }
}
