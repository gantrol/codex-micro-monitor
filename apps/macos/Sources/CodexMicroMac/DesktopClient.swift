import Foundation

@MainActor enum Desktop {
    static let services: DesktopServices? = {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MicroDesktop.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? DesktopServices.Type else { return nil }
        return type.init()
    }()
}

@MainActor final class DesktopClient {
    func execute(_ operation: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let service = Desktop.services else {
            throw NSError(domain: "MicroBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "MicroDesktop.bundle could not be loaded."])
        }
        let data = try JSONSerialization.data(withJSONObject: arguments), id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Data = try await withCheckedThrowingContinuation { continuation in
                service.execute(id, operation: operation, arguments: data) { result, error in
                    if let error {
                        if error.domain == "MicroBridge", error.code == 3 { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(throwing: error) }
                    } else if let result { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: CocoaError(.coderReadCorrupt)) }
                }
            }
            guard let value = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            return value
        } onCancel: { Task { @MainActor in service.cancel(id) } }
    }
    func close() async {
        guard let service = Desktop.services else { return }
        await withCheckedContinuation { continuation in service.close { continuation.resume() } }
    }
}
