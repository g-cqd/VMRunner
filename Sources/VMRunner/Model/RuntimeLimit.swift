import Foundation

/// The timer behind a machine's runtime limit: when the limit passes it asks the machine to shut down, and if the
/// machine is still running `gracePeriod` later it stops it by force. Time comes from the injected `Clock`, so a test
/// clock decides when each step fires; `VMController` keeps the part that needs a virtual machine.
@MainActor
final class RuntimeLimit {
    /// How long the guest gets to shut down cleanly before the plug is pulled.
    static let gracePeriod = Duration.seconds(30)

    private let sleep: (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    init<C: Clock>(clock: C) where C.Duration == Duration {
        sleep = { try await clock.sleep(for: $0) }
    }

    isolated deinit { task?.cancel() }

    /// Counts `limit` from now, replacing a limit that was already running.
    func start(after limit: Duration, requestStop: @escaping @MainActor () -> Void, forceStop: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [sleep] in
            do {
                try await sleep(limit)
                requestStop()
                try await sleep(Self.gracePeriod)
            } catch {
                return
            }
            await forceStop()
        }
    }

    /// Stops counting; neither step fires afterwards.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
