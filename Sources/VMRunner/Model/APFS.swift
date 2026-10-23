import Darwin
import Foundation
import os

/// Copy-on-write helpers. A clone shares every block with its source until one side writes, so duplicating,
/// snapshotting, or booting a throwaway copy of a 100 GB disk is instant and costs no space up front.
enum APFS {
    struct CloneError: LocalizedError {
        let source: URL
        let code: Int32

        var errorDescription: String? {
            if code == ELOOP { return "Won't clone \(source.lastPathComponent): it is a symbolic link, which could point anywhere." }
            return code == ENOTSUP || code == EXDEV
                ? "Copy-on-write cloning needs the source and destination on the same APFS volume."
                : "Couldn't clone \(source.lastPathComponent): \(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)"
        }
    }

    /// Clones a file or an entire directory tree atomically with `clonefile(2)`.
    ///
    /// The paths come from a bundle someone else may have made, so a source that is itself a symbolic link is refused:
    /// cloning the target would copy a file the bundle has no business with, and cloning the link would make a "private"
    /// copy that writes through to the original. `CLONE_NOFOLLOW` closes the window between this check and the call.
    static func clone(_ source: URL, to destination: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        guard (attributes?[.type] as? FileAttributeType) != .typeSymbolicLink else { throw CloneError(source: source, code: ELOOP) }
        // Swift bridges both paths to NUL-terminated C strings that stay valid for the duration of the call.
        guard unsafe clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
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

/// `snapshot.json` is data from disk, which a copied bundle controls: it is refused, never clamped, when it is too large or
/// holds a value the app could not have written.
extension Snapshot {
    /// The largest `snapshot.json` the app reads. A real one is a few hundred bytes.
    static let maxFileBytes = 64 << 10

    /// Reads and decodes a snapshot file, refusing one over `maxFileBytes` without reading the rest of it.
    static func load(from file: URL) throws -> Snapshot {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // One byte past the limit is enough to know the file is too large.
        return try decode(from: try handle.read(upToCount: maxFileBytes + 1) ?? Data())
    }

    static func decode(from data: Data) throws -> Snapshot {
        guard data.count <= maxFileBytes else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The snapshot is larger than 64 KiB"))
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        // Restoring a snapshot copies its size into the settings, so a size the editor couldn't have set is refused.
        guard (1...EditorLimits.maxDiskGiB).contains(snapshot.diskGiB) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The snapshot's disk size is out of range"))
        }
        guard snapshot.name.count <= EditorLimits.maxTextLength else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The snapshot's name is too long"))
        }
        return snapshot
    }
}

extension VMBundle {
    private func snapshotDirectory(_ id: UUID) -> URL { snapshots.appending(path: id.uuidString, directoryHint: .isDirectory) }

    func listSnapshots() -> [Snapshot] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        return
            directories
            .compactMap { directory -> Snapshot? in
                let snapshot: Snapshot
                do {
                    snapshot = try Snapshot.load(from: directory.appending(path: "snapshot.json"))
                } catch {
                    Log.storage.error(
                        "Ignoring snapshot folder \(directory.lastPathComponent, privacy: .private) (\(error.logKind, privacy: .public))")
                    return nil
                }
                // The folder name is the identity: a copied folder carries the original's id and would alias it.
                guard directory.lastPathComponent == snapshot.id.uuidString else {
                    Log.storage.error(
                        "Ignoring snapshot folder \(directory.lastPathComponent, privacy: .private): name doesn't match its id")
                    return nil
                }
                return snapshot
            }
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
        try AppPaths.createPrivateDirectory(directory)
        do {
            try APFS.clone(disk, to: directory.appending(path: disk.lastPathComponent))
            try APFS.clone(stateFile(for: config.guest), to: directory.appending(path: stateFile(for: config.guest).lastPathComponent))
            try JSONEncoder().encode(snapshot).writePrivately(to: directory.appending(path: "snapshot.json"))
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

    /// Clones everything the guest can write so the originals stay untouched, and gives this start its own machine
    /// identifier when `identity` is set (the bytes of a new one).
    func prepareEphemeral(guest: GuestOS, identity: Data? = nil) throws {
        discardEphemeral()
        try APFS.clone(disk, to: ephemeralDisk)
        switch guest {
        case .macOS: try APFS.clone(auxiliaryStorage, to: ephemeralAuxiliaryStorage)
        case .linux: try APFS.clone(efiVariables, to: ephemeralEFIVariables)
        }
        if let identity { try identity.writePrivately(to: ephemeralMachineIdentifier) }
    }

    /// Removes what one run leaves in the bundle: the disposable copies, the provisioning seed (built again at each start),
    /// and the host-information folder, whose last facts
    /// must not travel with a copied bundle. Runs at every stop, at launch for every machine that is not running, and
    /// before a disposable start.
    func discardEphemeral() {
        let leftovers = [ephemeralDisk, ephemeralAuxiliaryStorage, ephemeralEFIVariables, ephemeralMachineIdentifier, provisioningSeed]
        for file in leftovers + [hostInfoFolder] {
            remove(file)
        }
    }
}
