package import Foundation

/// The seed as cloud-init's NoCloud source finds it: an ISO 9660 volume labelled `cidata` with `user-data`, `meta-data`
/// and, when the spec gives one, `network-config` in its root. The same seed always gives the same bytes.
package enum SeedImage {
    /// The label NoCloud looks for. It accepts `cidata` and `CIDATA`: the Joliet label keeps the lowercase.
    static let label = "cidata"

    /// The image of `seed`: the same seed always gives the same bytes, so a digest of them identifies the seed.
    package static func bytes(for seed: CloudInitSeed) -> [UInt8] {
        var files = [
            ISOFile(name: "meta-data", contents: Array(seed.metaData.utf8)),
            ISOFile(name: "user-data", contents: Array(seed.userData.utf8)),
        ]
        if let network = seed.networkConfig { files.append(ISOFile(name: "network-config", contents: Array(network.utf8))) }
        return ISOImage.build(label: label, files: files)
    }

    /// Writes the image to `url`, replacing a file already there, and leaves it readable by its owner only (0400). The
    /// bytes go first to a new file beside it, created 0600 and made 0400 before it takes the name, so no moment exists
    /// when the file is more open than 0400.
    package static func write(_ seed: CloudInitSeed, to url: URL) throws {
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard manager.createFile(atPath: temporary.path, contents: Data(bytes(for: seed)), attributes: [.posixPermissions: 0o600])
        else { throw ProvisioningError(line: nil, "the seed image cannot be written beside \(url.lastPathComponent)") }
        do {
            try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: temporary.path)
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            try manager.moveItem(at: temporary, to: url)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}
