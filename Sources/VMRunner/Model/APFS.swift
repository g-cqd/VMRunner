import Darwin
import Foundation

/// Copy-on-write helpers. A clone shares every block with its source until one side writes, so duplicating,
/// snapshotting, or booting a throwaway copy of a 100 GB disk is instant and costs no space up front.
enum APFS {
    struct CloneError: LocalizedError {
        let source: URL
        let code: Int32

        var errorDescription: String? {
            code == ENOTSUP || code == EXDEV
                ? "Copy-on-write cloning needs the source and destination on the same APFS volume."
                : "Couldn't clone \(source.lastPathComponent): \(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)"
        }
    }

    /// Clones a file or an entire directory tree atomically with `clonefile(2)`.
    static func clone(_ source: URL, to destination: URL) throws {
        // Swift bridges both paths to NUL-terminated C strings that stay valid for the duration of the call.
        guard unsafe clonefile(source.path, destination.path, 0) == 0 else {
            throw CloneError(source: source, code: errno)
        }
    }
}

enum SnapshotError: LocalizedError {
    case machineIsSuspended

    var errorDescription: String? {
        "This machine is suspended. Resume and shut it down, or discard its suspended state, before taking a snapshot."
    }
}

struct Snapshot: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var date = Date()
    var diskGiB: Int
}

extension VMBundle {
    private func snapshotDirectory(_ id: UUID) -> URL { snapshots.appending(path: id.uuidString, directoryHint: .isDirectory) }

    func listSnapshots() -> [Snapshot] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return
            directories
            .compactMap { try? decoder.decode(Snapshot.self, from: Data(contentsOf: $0.appending(path: "snapshot.json"))) }
            // Restoring a snapshot copies its size into the settings, so a size the editor couldn't have set is refused.
            .filter { (1...EditorLimits.maxDiskGiB).contains($0.diskGiB) }
            .sorted { $0.date > $1.date }
    }

    /// Clones the disk and firmware state. The machine must be stopped so the disk is consistent.
    ///
    /// A suspended machine is refused: its disk only matches its saved memory, which a snapshot doesn't capture,
    /// so restoring that snapshot later would boot a crash-consistent disk without saying so.
    func takeSnapshot(named name: String, config: VMConfig) throws -> Snapshot {
        guard !hasSavedState else { throw SnapshotError.machineIsSuspended }
        let snapshot = Snapshot(name: name, diskGiB: config.diskGiB)
        let directory = snapshotDirectory(snapshot.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try APFS.clone(disk, to: directory.appending(path: disk.lastPathComponent))
            try APFS.clone(stateFile(for: config.guest), to: directory.appending(path: stateFile(for: config.guest).lastPathComponent))
            try JSONEncoder().encode(snapshot).write(to: directory.appending(path: "snapshot.json"))
        } catch {
            remove(directory)
            throw error
        }
        return snapshot
    }

    /// Swaps the disk and firmware state for the snapshot's. Both clones are staged before either is replaced,
    /// so a failed clone leaves the machine as it was.
    func restoreSnapshot(_ snapshot: Snapshot, guest: GuestOS) throws {
        let directory = snapshotDirectory(snapshot.id)
        let state = stateFile(for: guest)
        let pairs = [
            (disk, directory.appending(path: disk.lastPathComponent)), (state, directory.appending(path: state.lastPathComponent)),
        ]
        var staged: [(destination: URL, clone: URL)] = []
        do {
            for (destination, source) in pairs {
                let clone = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).clone")
                try APFS.clone(source, to: clone)
                staged.append((destination, clone))
            }
            for item in staged { _ = try FileManager.default.replaceItemAt(item.destination, withItemAt: item.clone) }
        } catch {
            for item in staged { remove(item.clone) }
            throw error
        }
        discardSavedState()
    }

    func deleteSnapshot(_ snapshot: Snapshot) {
        remove(snapshotDirectory(snapshot.id))
    }

    // MARK: Disposable copies

    /// Clones everything the guest can write so the originals stay untouched.
    func prepareEphemeral(guest: GuestOS) throws {
        discardEphemeral()
        try APFS.clone(disk, to: ephemeralDisk)
        switch guest {
        case .macOS: try APFS.clone(auxiliaryStorage, to: ephemeralAuxiliaryStorage)
        case .linux: try APFS.clone(efiVariables, to: ephemeralEFIVariables)
        }
    }

    func discardEphemeral() {
        for file in [ephemeralDisk, ephemeralAuxiliaryStorage, ephemeralEFIVariables] { remove(file) }
    }
}
