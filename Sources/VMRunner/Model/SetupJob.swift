import Observation

/// Progress of a long-running setup step (download, verify, install).
///
/// A job is running until its work ends, by finishing, being cancelled and unwinding, or failing; `isFinished` says it has.
/// It stays in the library's table while it runs, unwinds, or shows its failure.
@MainActor @Observable
final class SetupJob {
    var title = "Preparing…"
    /// Something the user should know about this setup that is not a failure, for example that a newer release was passed over.
    var notice: String?
    var fraction: Double?
    var error: String?
    var task: Task<Void, Never>?
    /// The job's work has ended. A failed job is finished and still shown, with its error.
    var isFinished = false

    func cancel() {
        task?.cancel()
    }
}
