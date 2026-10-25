import Foundation

/// A container machine's workload: one container runner process, followed through its events.
///
/// `start()` returns when the container is up, that is when the runner reports that it booted or started the command, or when
/// the container printed or ended first; a runner that ends before that fails the start with what it said. After that the
/// runner's end is reported as the machine stopping: cleanly when the runner passed or was stopped, with a message when the
/// container or the runner failed. A stop the app asked for is never an error, whatever signal ended the runner.
@MainActor
final class ContainerWorkload: Workload {
    /// The runner's exit statuses that are not failures: it passed, or it was stopped before the command ended.
    private static let cleanStatuses: Set<Int32> = [0, 75]
    /// The runner's exit status for "the container ran and its result was wrong".
    private static let failedStatus: Int32 = 1

    private let process: ContainerProcess
    private let scratch: URL
    private var starting: CheckedContinuation<Void, any Error>?
    private var stopAsked = false
    private var killed = false

    init(process: ContainerProcess, scratch: URL) {
        self.process = process
        self.scratch = scratch
    }

    var capabilities: WorkloadCapabilities { [] }
    var canStop: Bool { process.isRunning }
    var onGuestStopped: (@MainActor () -> Void)?
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)?
    var networkCutoff: NetworkCutoff? { nil }
    var workloadLog: ContainerLog? { process.log }

    func start() async throws {
        try ContainerScratch.prepare(scratch)
        process.onEvent = { [weak self] in self?.apply($0) }
        process.onExit = { [weak self] in self?.ended($0) }
        try process.start()
        // No event or exit can be applied before this suspends: they run on this actor.
        try await withCheckedThrowingContinuation { starting = $0 }
    }

    /// Writes the stop line; the runner stops the container and exits, or the process is ended by signal after a grace.
    func requestStop() throws {
        guard process.isRunning else { throw ContainerProcessError(reason: "The container is not running.") }
        stopAsked = true
        process.stop()
    }

    /// Ends the runner at once and returns when it has ended.
    func stop() async throws {
        guard process.isRunning else { return }
        killed = true
        process.kill()
        _ = await process.waitForExit()
    }

    // MARK: Following the runner

    private func apply(_ event: ContainerEvent) {
        guard starting != nil else { return }
        switch event {
        case .phase(let name, _):
            if name == "boot" || name == "run" { becomeReady() }
        case .output, .exited:
            becomeReady()
        case .error, .finished:
            break
        }
    }

    private func becomeReady() {
        let pending = starting
        starting = nil
        pending?.resume()
    }

    private func ended(_ exit: ContainerExit) {
        let failure = failure(of: exit)
        if let pending = starting {
            starting = nil
            if let failure {
                pending.resume(throwing: ContainerProcessError(reason: failure))
                return
            }
            // The start returns, but the run is over: report it, in this order.
            pending.resume()
        }
        if let failure { onStoppedWithError?(failure) } else { onGuestStopped?() }
    }

    /// Why the run failed, or `nil` when it ended as it should.
    private func failure(of exit: ContainerExit) -> String? {
        if exit.signaled { return stopAsked || killed ? nil : "The container runner was ended by signal \(exit.status)." }
        if Self.cleanStatuses.contains(exit.status) { return nil }
        let log = process.log
        if exit.status == Self.failedStatus, let status = log.containerStatus, status != 0 {
            return "The container exited with status \(status)."
        }
        return log.errors.last ?? "The container runner stopped with status \(exit.status)."
    }
}
