import Observation

/// Progress of a long-running setup step (download, verify, install).
@MainActor @Observable
final class SetupJob {
    var title = "Preparing…"
    var fraction: Double?
    var error: String?
    var task: Task<Void, Never>?

    var isRunning: Bool { task != nil && error == nil }

    func cancel() {
        task?.cancel()
    }
}
