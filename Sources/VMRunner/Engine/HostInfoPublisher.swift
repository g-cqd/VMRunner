import Foundation
import os

/// Writes this Mac's facts into the host-information share of one run: at the start, every `interval`, and at each change
/// of the Mac's network path when that is shared. It stops when it is released, with the machine that owns it.
@MainActor
final class HostInfoPublisher {
    /// Produces a fresh stream of path samples when publishing starts.
    typealias Paths = @Sendable () -> any AsyncSequence<HostNetworkPath, Never>

    /// How often the files are rewritten. Battery, power and heat change slowly; a path change is written at once.
    static let interval = Duration.seconds(60)

    private let directory: URL
    private let sharing: HostInfoSharing
    private let paths: Paths
    private let read: @MainActor (HostNetworkPath?) -> HostFacts
    private let sleep: @Sendable (Duration) async throws -> Void
    private var path: HostNetworkPath?
    private var tasks: [Task<Void, Never>] = []

    /// `clock`, `paths` and `read` default to the real ones; a test passes its own.
    init<C: Clock>(
        directory: URL, sharing: HostInfoSharing, clock: C = ContinuousClock(),
        paths: @escaping Paths = HostNetworkPath.systemPaths,
        read: @escaping @MainActor (HostNetworkPath?) -> HostFacts = HostFacts.current(network:)
    ) where C.Duration == Duration {
        self.directory = directory
        self.sharing = sharing
        self.paths = paths
        self.read = read
        sleep = { try await clock.sleep(for: $0) }
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    /// Writes the files now, then keeps them current until the publisher is released. Idempotent.
    func start() {
        guard tasks.isEmpty else { return }
        publish()
        let sleep = sleep
        tasks.append(
            Task { [weak self] in
                while (try? await sleep(Self.interval)) != nil {
                    self?.publish()
                }
            })
        guard sharing.networkPath else { return }
        let paths = paths
        tasks.append(
            Task { [weak self] in
                for await path in paths() {
                    guard let self else { return }
                    self.path = path
                    self.publish()
                }
            })
    }

    /// Writes the file of every shared category and removes any other, so the folder holds exactly what is shared.
    private func publish() {
        let files = read(path).files(for: sharing)
        for name in HostFacts.fileNames {
            let file = directory.appending(path: name)
            do {
                if let text = files[name] {
                    try Data(text.utf8).write(to: file, options: .atomic)
                } else if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                Log.machine.error("Couldn't write host information (\(error.logKind, privacy: .public))")
            }
        }
    }
}
