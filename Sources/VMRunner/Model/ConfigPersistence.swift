import AsyncAlgorithms
import Foundation

/// Coalesces settings writes. Editing a text field changes the config on every keystroke; writing the file each
/// time is wasted work on the main actor, so a change is held until edits have paused for `quietPeriod`, and only
/// the newest config of each machine is written. Anything that reads the files on disk (duplicating a machine,
/// quitting) calls `flush()` first, so nothing is ever lost or stale.
@MainActor
final class ConfigPersistence {
    /// Called with the config and the error when a write fails.
    var onFailure: (VMConfig, any Error) -> Void = { _, _ in }

    private let write: (VMConfig) throws -> Void
    private var pending: [UUID: VMConfig] = [:]
    private let changes: AsyncStream<Void>.Continuation
    private var flusher: Task<Void, Never>?

    var hasPendingWrites: Bool { !pending.isEmpty }

    init<C: Clock>(quietPeriod: C.Duration, clock: C, write: @escaping (VMConfig) throws -> Void) where C.Duration == Duration {
        self.write = write
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = continuation
        flusher = Task { [weak self] in
            for await _ in stream.debounce(for: quietPeriod, clock: clock) {
                self?.flush()
            }
        }
    }

    isolated deinit {
        changes.finish()
        flusher?.cancel()
    }

    /// Remembers `config` to be written once edits pause, replacing any older one for the same machine.
    func schedule(_ config: VMConfig) {
        pending[config.id] = config
        changes.yield()
    }

    /// Writes everything pending now.
    func flush() {
        guard hasPendingWrites else { return }
        let work = InputPath.begin("config write")
        defer { InputPath.end(work) }
        let configs = pending
        pending = [:]
        for config in configs.values {
            do {
                try write(config)
            } catch {
                onFailure(config, error)
            }
        }
    }

    /// Forgets a machine's pending write, for a machine that is being deleted.
    func discard(_ id: UUID) {
        pending[id] = nil
    }
}
