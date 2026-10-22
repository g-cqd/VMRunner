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
                    try Self.overwrite(file, with: Data(text.utf8))
                } else if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                Log.machine.error("Couldn't write host information (\(error.logKind, privacy: .public))")
            }
        }
    }

    /// Writes `data` over `file` in place: the file keeps its name and inode, and is truncated and then written with its
    /// whole content in one call. A guest reading it through the share sees the old text, the new text or, for a moment, an
    /// empty file, never a missing one: a replace by rename made the name vanish for about a second in a Linux guest, whose
    /// virtio-fs entry cache still held the old file. The file is opened without following a link: a link at that name
    /// makes the write fail instead of writing through it.
    private static func overwrite(_ file: URL, with data: Data) throws {
        // `open` gets a NUL-terminated copy of the path that outlives the call; O_NOFOLLOW makes it fail with ELOOP on a link.
        let descriptor = unsafe open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}
