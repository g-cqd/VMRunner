// The provisioning library has no caller outside its tests until a later change attaches the seed to a machine, so a
// declaration only the tests reach is expected here; every other dead-code rule still applies.
// @dw:disable referenced-only-by-tests

package import Foundation

/// The seed as cloud-init's NoCloud source finds it: an ISO 9660 volume labelled `cidata` with `user-data`, `meta-data`
/// and, when the spec gives one, `network-config` in its root. The same seed always gives the same bytes.
package enum SeedImage {
    /// The label NoCloud looks for. It accepts `cidata` and `CIDATA`: the Joliet label keeps the lowercase.
    static let label = "cidata"

    static func bytes(for seed: CloudInitSeed) -> [UInt8] {
        var files = [
            ISOFile(name: "meta-data", contents: Array(seed.metaData.utf8)),
            ISOFile(name: "user-data", contents: Array(seed.userData.utf8)),
        ]
        if let network = seed.networkConfig { files.append(ISOFile(name: "network-config", contents: Array(network.utf8))) }
        return ISOImage.build(label: label, files: files)
    }

    /// Writes the image to `url`, replacing a file already there, and leaves it read-only (0444).
    package static func write(_ seed: CloudInitSeed, to url: URL) throws {
        try Data(bytes(for: seed)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    }
}
