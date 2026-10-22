import Foundation

/// Where Alpine Linux publishes its aarch64 netboot image, how the newest signed release is picked from the directory
/// listing, and the key that signs it.
///
/// A netboot image is a kernel and an initial ramdisk (plus a module file) that boot a machine with no disk at all: the
/// ramdisk fetches the rest of the system over the network. That is what a console-driven test guest needs.
enum AlpineNetboot {
    static let host = "dl-cdn.alpinelinux.org"
    static let directory = "/alpine/latest-stable/releases/aarch64/"
    /// The key file Alpine publishes for its release signer, and the fingerprint it must have. The file is untrusted until
    /// its primary key is exactly this fingerprint.
    static let keyURL = "https://alpinelinux.org/keys/ncopa.asc"
    static let keyFingerprint = "0482D84022F52DF1C4E7CD43293ACD0907D9495A"

    /// What the vendor's listing shows for one release.
    struct Release: Equatable, Sendable {
        /// `3.24.2`: three numbers, so a release candidate (`3.24.0_rc1`) is never one.
        let version: String
        let hasChecksum: Bool
        let hasSignature: Bool

        var components: [Int] { version.split(separator: ".").compactMap { Int($0) } }
        var archive: String { AlpineNetboot.archiveName(version) }
        var checksumFile: String { archive + ".sha256" }
        var signatureFile: String { archive + ".asc" }
    }

    /// The release to fetch, and the newer ones that were passed over because they are not signed yet.
    struct Choice: Equatable, Sendable {
        let release: Release
        let passedOver: [String]
    }

    static func archiveName(_ version: String) -> String {
        "alpine-netboot-\(version)-aarch64.tar.gz"
    }

    static func url(of file: String) -> URL? {
        URL(string: "https://\(host)\(directory)\(file)")
    }

    /// The releases a directory listing (the HTML index the vendor's server returns) names, in no particular order.
    static func releases(inListing html: String) -> [Release] {
        let names = Set(links(in: html))
        let prefix = "alpine-netboot-"
        let suffix = "-aarch64.tar.gz"
        var found: [Release] = []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let version = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard isVersion(version) else { continue }
            found.append(
                Release(version: version, hasChecksum: names.contains(name + ".sha256"), hasSignature: names.contains(name + ".asc")))
        }
        return found
    }

    /// The newest release that has a checksum and a signature. Newer releases without a signature are named in `passedOver`.
    static func choose(from releases: [Release]) throws -> Choice {
        let newestFirst = releases.filter(\.hasChecksum).sorted { $1.components.lexicographicallyPrecedes($0.components) }
        guard let signed = newestFirst.first(where: \.hasSignature) else {
            throw ToolError("the listing names no Alpine netboot release with both a .sha256 and a .asc file")
        }
        let newer = newestFirst.prefix { $0 != signed }.map(\.version)
        return Choice(release: signed, passedOver: newer)
    }

    /// `3.24.2`: three groups of digits separated by dots.
    static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCIIDigit) }
    }

    /// The targets of the `href="..."` attributes in `html`.
    static func links(in html: String) -> [String] {
        var targets: [String] = []
        var rest = html[...]
        while let start = rest.range(of: "href=\"") {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            targets.append(String(rest[..<end]))
            rest = rest[end...]
        }
        return targets
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
