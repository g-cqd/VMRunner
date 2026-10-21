import Foundation
import os

/// One host file or folder a machine's configuration hands to the guest.
///
/// A `config.json` is data on disk, so a bundle copied from elsewhere can name any path the user can read. The guest only
/// gets paths the user chose in this app, which `HostPathApprovals` remembers per machine.
struct HostPathGrant: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case sharedFolder, extraDisk, installer }

    var kind: Kind
    var path: String
    /// Whether the guest may change what the path points to.
    var writable: Bool

    init(_ kind: Kind, _ path: String, writable: Bool) {
        self.kind = kind
        self.path = URL(filePath: path).standardizedFileURL.path
        self.writable = writable
    }

    /// Whether approving `self` also approves `other`: the same path and kind, and no more access than was approved.
    func covers(_ other: Self) -> Bool {
        kind == other.kind && path == other.path && (writable || !other.writable)
    }

    var summary: String {
        switch kind {
        case .sharedFolder: "\(path) (shared folder, \(writable ? "read and write" : "read-only"))"
        case .extraDisk: "\(path) (extra disk, \(writable ? "writable" : "read-only"))"
        case .installer: "\(path) (installer image, read-only)"
        }
    }
}

extension VMConfig {
    /// Every host path this configuration hands to the guest when the machine starts.
    var hostGrants: [HostPathGrant] {
        var grants = sharedFolders.map { HostPathGrant(.sharedFolder, $0.path, writable: !$0.readOnly) }
        grants += extraDisks.map { HostPathGrant(.extraDisk, $0.path, writable: !$0.readOnly) }
        if let installer = attachedInstallerPath { grants.append(HostPathGrant(.installer, installer, writable: false)) }
        return grants
    }
}

/// The host paths the user approved for each machine, kept in one small file beside the machines folder, never inside a
/// bundle, so copying a bundle can't bring its approvals along.
///
/// A missing file means the app has not recorded approvals before: the machines already on disk then are the user's own
/// (made by an earlier version) and `grandfather` approves their current paths once. A bundle that shows up afterwards has
/// no record, so nothing of it is approved. A file that exists but can't be read counts as "recorded, nothing approved".
struct HostPathApprovals {
    private struct Stored: Codable {
        var machines: [String: [HostPathGrant]]
    }

    let file: URL
    /// No approvals file existed when this was opened.
    private(set) var isFresh: Bool
    private var machines: [UUID: Set<HostPathGrant>] = [:]

    init(file: URL) {
        self.file = file
        isFresh = !FileManager.default.fileExists(atPath: file.path)
        guard !isFresh else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
            for (key, grants) in stored.machines {
                if let id = UUID(uuidString: key) { machines[id] = Set(grants) }
            }
        } catch {
            Log.storage.error("Couldn't read the host path approvals: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The grants of `grants` that no approval for `id` covers.
    func missing(_ grants: [HostPathGrant], for id: UUID) -> [HostPathGrant] {
        let approved = machines[id] ?? []
        return grants.filter { grant in !approved.contains { $0.covers(grant) } }
    }

    mutating func approve(_ grants: [HostPathGrant], for id: UUID) throws {
        machines[id, default: []].formUnion(grants)
        try save()
    }

    /// A copy starts with what its source had approved, no more.
    mutating func inherit(from source: UUID, to copy: UUID) throws {
        machines[copy] = machines[source] ?? []
        try save()
    }

    mutating func forget(_ id: UUID) throws {
        guard machines.removeValue(forKey: id) != nil else { return }
        try save()
    }

    /// The one-time upgrade step: approves what existing machines have now, then records that it happened.
    mutating func grandfather(_ configs: [VMConfig]) throws {
        guard isFresh else { return }
        for config in configs { machines[config.id, default: []].formUnion(config.hostGrants) }
        try save()
    }

    private mutating func save() throws {
        try AppPaths.createPrivateDirectory(file.deletingLastPathComponent())
        let stored = Stored(
            machines: Dictionary(uniqueKeysWithValues: machines.map { ($0.key.uuidString, $0.value.sorted(by: Self.order)) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        isFresh = false
    }

    private static func order(_ lhs: HostPathGrant, _ rhs: HostPathGrant) -> Bool {
        (lhs.path, lhs.kind.rawValue, lhs.writable ? 1 : 0) < (rhs.path, rhs.kind.rawValue, rhs.writable ? 1 : 0)
    }
}
