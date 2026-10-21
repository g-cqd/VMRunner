import Foundation
import os

/// Where VMRunner keeps its data. Everything is private to the current user (mode 0700).
enum AppPaths {
    static let root = URL.applicationSupportDirectory.appending(path: "VMRunner", directoryHint: .isDirectory)
    static let machines = root.appending(path: "Machines", directoryHint: .isDirectory)
    /// Downloaded IPSW / ISO files, shared between machines.
    static let images = root.appending(path: "Images", directoryHint: .isDirectory)
    static let partialDownloads = images.appending(path: ".partial", directoryHint: .isDirectory)

    /// Creates `url` and any missing parents, readable only by the current user.
    static func createPrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        var missing: [URL] = []
        var cursor = url
        while !fileManager.fileExists(atPath: cursor.path), cursor.path != "/" {
            missing.append(cursor)
            cursor.deleteLastPathComponent()
        }
        for directory in missing.reversed() {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// On-disk layout of one machine: `<machines>/<uuid>.vm/`.
struct VMBundle: Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    init(id: UUID, in machinesDirectory: URL) {
        url = machinesDirectory.appending(path: "\(id.uuidString).vm", directoryHint: .isDirectory)
    }

    var config: URL { url.appending(path: "config.json") }
    var disk: URL { url.appending(path: "Disk.img") }
    var auxiliaryStorage: URL { url.appending(path: "AuxiliaryStorage") }
    var hardwareModel: URL { url.appending(path: "HardwareModel") }
    var machineIdentifier: URL { url.appending(path: "MachineIdentifier") }
    var efiVariables: URL { url.appending(path: "EFIVariables.fd") }
    var savedState: URL { url.appending(path: "SavedState.vzvmsave") }

    // Disposable copies used while an ephemeral machine runs.
    var ephemeralDisk: URL { url.appending(path: "Disk.ephemeral.img") }
    var ephemeralAuxiliaryStorage: URL { url.appending(path: "AuxiliaryStorage.ephemeral") }
    var ephemeralEFIVariables: URL { url.appending(path: "EFIVariables.ephemeral.fd") }
    var snapshots: URL { url.appending(path: "Snapshots", directoryHint: .isDirectory) }

    func activeDisk(ephemeral: Bool) -> URL { ephemeral ? ephemeralDisk : disk }
    func activeAuxiliaryStorage(ephemeral: Bool) -> URL { ephemeral ? ephemeralAuxiliaryStorage : auxiliaryStorage }
    func activeEFIVariables(ephemeral: Bool) -> URL { ephemeral ? ephemeralEFIVariables : efiVariables }

    /// The per-guest firmware state file: macOS auxiliary storage or the EFI variable store.
    func stateFile(for guest: GuestOS) -> URL { guest == .macOS ? auxiliaryStorage : efiVariables }

    var hasSavedState: Bool { FileManager.default.fileExists(atPath: savedState.path) }

    func create() throws {
        try AppPaths.createPrivateDirectory(url)
    }

    func discardSavedState() {
        remove(savedState)
    }

    /// Bytes actually allocated on disk (the disk image is sparse).
    var allocatedBytes: Int64 { DiskUsage.allocatedBytes(in: url) }

    /// Removes a file, logging anything other than "already gone".
    func remove(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            Log.storage.error(
                "Couldn't remove \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum DiskUsage {
    /// Total bytes allocated on disk for every file under `directory`. Walks the tree, so call it off the main thread.
    static func allocatedBytes(in directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

enum DiskImageError: LocalizedError {
    case sizeOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .sizeOutOfRange(let gibibytes):
            "A disk of \(gibibytes) GiB isn't possible: it must be from 1 to \(EditorLimits.maxDiskGiB) GiB."
        }
    }
}

enum DiskImage {
    /// A size in bytes, checked before it is shifted: a negative or huge count would trap in the conversion.
    private static func bytes(gibibytes: Int) throws -> UInt64 {
        guard (1...EditorLimits.maxDiskGiB).contains(gibibytes) else { throw DiskImageError.sizeOutOfRange(gibibytes) }
        return UInt64(gibibytes) << 30
    }

    /// Creates a sparse raw image. APFS only allocates blocks the guest writes.
    static func create(at url: URL, gibibytes: Int) throws {
        let size = try bytes(gibibytes: gibibytes)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    /// Grows a raw image. The guest still has to extend its partition and filesystem.
    static func grow(at url: URL, toGibibytes size: Int) throws {
        let target = try bytes(gibibytes: size)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let current = try handle.seekToEnd()
        guard target > current else { return }
        try handle.truncate(atOffset: target)
    }
}
