import Foundation

/// Owns observation scheduling only. A slow read consumes its interval instead
/// of adding another full delay, and wake events never create overlapping reads.
@MainActor final class ObservationCoordinator {
    enum Channel: CaseIterable { case native, activity, catalogue }
    @MainActor private final class Worker {
        private var task: Task<Void, Never>?
        private var sleeper: Task<Void, Error>?
        private var pending = false

        func start(interval: TimeInterval, action: @escaping @MainActor () async -> Void) {
            guard task == nil else { return }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    let started = ProcessInfo.processInfo.systemUptime
                    await action()
                    guard let self, !Task.isCancelled else { return }
                    if pending { pending = false; continue }
                    let delay = max(0.05, interval - (ProcessInfo.processInfo.systemUptime - started))
                    let sleeper = Task { try await Task.sleep(for: .seconds(delay)) }
                    self.sleeper = sleeper
                    _ = try? await sleeper.value
                    self.sleeper = nil; pending = false
                }
            }
        }
        func wake() { pending = true; sleeper?.cancel() }
        func stop() { task?.cancel(); sleeper?.cancel(); task = nil; sleeper = nil; pending = false }
    }

    private var workers: [Channel: Worker] = [:]
    var isRunning: Bool { !workers.isEmpty }

    func start(native: @escaping @MainActor () async -> Void,
               activity: @escaping @MainActor () async -> Void,
               catalogue: @escaping @MainActor () async -> Void) {
        guard !isRunning else { return }
        for (channel, interval, action) in [(Channel.native, 0.65, native), (.activity, 0.2, activity), (.catalogue, 8.0, catalogue)] {
            let worker = Worker(); workers[channel] = worker
            worker.start(interval: interval, action: action)
        }
    }
    func wake(_ channel: Channel) { workers[channel]?.wake() }
    func stop() { workers.values.forEach { $0.stop() }; workers = [:] }
}
