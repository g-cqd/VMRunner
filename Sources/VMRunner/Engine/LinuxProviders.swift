import Foundation
import RegexBuilder

/// A dotted release number such as `10.2` or `3.24.2`, compared component by component so that `10.10` is
/// newer than `10.2`. A missing trailing component sorts first (`26.04` is older than `26.04.1`).
struct ReleaseVersion: Comparable, Sendable {
    private let components: [Int]

    /// Parses numbers separated by `.` or `-`; returns nil for anything else, including an empty string.
    init?(_ text: some StringProtocol) {
        let parts = text.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "-" }
        let numbers = parts.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == parts.count else { return nil }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// An installer ISO chosen from a provider: its path relative to the provider's directory and its release number.
struct LinuxRelease: Equatable, Sendable {
    /// For example `debian-13.7.0-arm64-netinst.iso` or `netboot/mini.iso`. Never contains a `..` component.
    var path: String
    /// The release text the file name carries (`13.7.0`); empty for a fixed path.
    var version: String
}

/// How one distribution publishes an installer ISO and its SHA-256: where to look, which file is the newest,
/// and how to read the checksum. Adding a distribution means describing it here, not writing new fetch code.
struct LinuxProvider: Sendable {
    /// How the ISO is found.
    enum ISO: Sendable {
        /// The newest file in the directory listing named `<prefix><release number><suffix>`, for example
        /// `debian-13.7.0-arm64-netinst.iso`. Release numbers are ASCII digits separated by `.` or `-`, so
        /// `latest` aliases and `_rc` builds never match.
        case newest(prefix: String, suffix: String)
        /// A file at a fixed path relative to the directory; no listing is fetched.
        case fixed(path: String)
    }

    /// Where the checksum is published.
    enum ChecksumLocation: Sendable {
        /// A file next to the ISO named `<iso>.<suffix>`.
        case sibling(suffix: String)
        /// One file in the directory that lists many images.
        case shared(fileName: String)
        /// One file in the directory whose name depends on the release number (Fedora's `Fedora-Server-44-1.7-aarch64-CHECKSUM`).
        case sharedPerRelease(@Sendable (_ version: String) -> String)
    }

    /// How a checksum line names its file.
    enum ChecksumFormat: Sendable {
        /// `SHA256 (name) = <hex>`
        case bsd
        /// `<hex>  name`, `<hex> *name` or `<hex>  ./name`
        case gnu

        /// The lowercase SHA-256 on the line that names exactly `entry`, or nil if no line does. Other
        /// lines, comments and signature armor are ignored, so a file that lists many images can't
        /// supply another image's hash.
        func sha256(for entry: String, in text: String) -> String? {
            let digest = Regex { Capture { Repeat(count: 64) { .asciiHexDigit } } }
            for line in text.split(whereSeparator: \.isNewline) {
                let named: (name: Substring, digest: Substring)?
                switch self {
                case .bsd:
                    let pattern = Regex {
                        "SHA256 ("
                        Capture { OneOrMore(.anyOf(")").inverted) }
                        ") = "
                        digest
                        ZeroOrMore(.horizontalWhitespace)
                    }
                    named = line.wholeMatch(of: pattern).map { ($0.output.1, $0.output.2) }
                case .gnu:
                    let pattern = Regex {
                        digest
                        " "
                        ChoiceOf {
                            " "
                            "*"
                        }
                        Optionally("./")
                        Capture { OneOrMore(.whitespace.inverted) }
                        ZeroOrMore(.horizontalWhitespace)
                    }
                    named = line.wholeMatch(of: pattern).map { ($0.output.2, $0.output.1) }
                }
                if let named, named.name == entry { return named.digest.lowercased() }
            }
            return nil
        }
    }

    var host: String
    /// Absolute path of the directory, with a trailing slash.
    var directoryPath: String
    var iso: ISO
    var checksum: ChecksumLocation
    var format: ChecksumFormat

    /// The HTTPS URL of the provider's directory.
    func directoryURL() throws(SetupError) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = directoryPath
        guard let url = components.url else { throw .missingFile("directory \(host)\(directoryPath)") }
        return url
    }

    /// Where `release`'s checksum is published.
    func checksumURL(for release: LinuxRelease) throws(SetupError) -> URL {
        let directory = try directoryURL()
        switch checksum {
        case .sibling(let suffix): return directory.appending(path: "\(release.path).\(suffix)")
        case .shared(let fileName): return directory.appending(path: fileName)
        case .sharedPerRelease(let fileName): return directory.appending(path: fileName(release.version))
        }
    }

    /// Finds the newest ISO of a matching directory listing (HTML or plain) by numeric release comparison.
    static func newest(inListing listing: String, prefix: String, suffix: String) -> LinuxRelease? {
        let matcher = Regex {
            prefix
            Capture {
                OneOrMore(.asciiDigit)
                ZeroOrMore {
                    ChoiceOf {
                        "."
                        "-"
                    }
                    OneOrMore(.asciiDigit)
                }
            }
            suffix
        }
        let href = Regex {
            "href=\""
            Capture { OneOrMore(.anyOf("\"").inverted) }
            "\""
        }
        let names = Set(listing.matches(of: href).map { String($0.output.1) })
        let candidates = names.compactMap { name -> (release: LinuxRelease, version: ReleaseVersion)? in
            guard let match = name.wholeMatch(of: matcher), let version = ReleaseVersion(match.output.1) else { return nil }
            return (LinuxRelease(path: name, version: String(match.output.1)), version)
        }
        return candidates.max { $0.version < $1.version }?.release
    }

    /// Finds the newest ISO and its published SHA-256.
    /// - Throws: `SetupError` if the directory has no matching ISO or the checksum file has no line for it.
    func resolve() async throws -> ImageSource {
        let directory = try directoryURL()
        let release: LinuxRelease
        switch iso {
        case .fixed(let path):
            release = LinuxRelease(path: path, version: "")
        case .newest(let prefix, let suffix):
            guard let newest = Self.newest(inListing: try await Self.text(at: directory), prefix: prefix, suffix: suffix) else {
                throw SetupError.missingFile("a matching ISO in \(directory)")
            }
            release = newest
        }
        let checksumURL = try checksumURL(for: release)
        guard let digest = format.sha256(for: release.path, in: try await Self.text(at: checksumURL)) else {
            throw SetupError.missingFile("the SHA-256 of \(release.path) in \(checksumURL.lastPathComponent)")
        }
        return .remote(directory.appending(path: release.path), checksum: Checksum(algorithm: .sha256, value: digest))
    }

    private static func text(at url: URL) async throws -> String {
        let data = try await Network.fetchSmall(url)
        guard let text = String(bytes: data, encoding: .utf8) else { throw SetupError.missingFile("readable text at \(url)") }
        return text
    }
}

// MARK: Distributions

extension LinuxProvider {
    static func centOSStream(release: Int, flavor: String) -> Self {
        Self(
            host: "mirror.stream.centos.org", directoryPath: "/\(release)-stream/BaseOS/aarch64/iso/",
            iso: .newest(prefix: "CentOS-Stream-\(release)-", suffix: "-aarch64-\(flavor).iso"),
            checksum: .sibling(suffix: "SHA256SUM"), format: .bsd)
    }

    static let debianNetinst = Self(
        host: "cdimage.debian.org", directoryPath: "/debian-cd/current/arm64/iso-cd/",
        iso: .newest(prefix: "debian-", suffix: "-arm64-netinst.iso"),
        checksum: .shared(fileName: "SHA256SUMS"), format: .gnu)

    static let debianNetbootMini = Self(
        host: "deb.debian.org", directoryPath: "/debian/dists/stable/main/installer-arm64/current/images/",
        iso: .fixed(path: "netboot/mini.iso"), checksum: .shared(fileName: "SHA256SUMS"), format: .gnu)

    static let alpineVirt = Self(
        host: "dl-cdn.alpinelinux.org", directoryPath: "/alpine/latest-stable/releases/aarch64/",
        iso: .newest(prefix: "alpine-virt-", suffix: "-aarch64.iso"),
        checksum: .sibling(suffix: "sha256"), format: .gnu)

    static func almaLinux(release: Int, flavor: String) -> Self {
        Self(
            host: "repo.almalinux.org", directoryPath: "/almalinux/\(release)/isos/aarch64/",
            iso: .newest(prefix: "AlmaLinux-", suffix: "-aarch64-\(flavor).iso"),
            checksum: .shared(fileName: "CHECKSUM"), format: .bsd)
    }

    static func rocky(release: Int, flavor: String) -> Self {
        Self(
            host: "download.rockylinux.org", directoryPath: "/pub/rocky/\(release)/isos/aarch64/",
            iso: .newest(prefix: "Rocky-", suffix: "-aarch64-\(flavor).iso"),
            checksum: .sibling(suffix: "CHECKSUM"), format: .bsd)
    }

    /// The live-server installer of an Ubuntu release such as `26.04`; its point releases (`26.04.1`) share the directory.
    static func ubuntuServer(release: String) -> Self {
        Self(
            host: "cdimage.ubuntu.com", directoryPath: "/ubuntu/releases/\(release)/release/",
            iso: .newest(prefix: "ubuntu-", suffix: "-live-server-arm64.iso"),
            checksum: .shared(fileName: "SHA256SUMS"), format: .gnu)
    }

    static func fedoraServerNetinst(release: Int) -> Self {
        Self(
            host: "dl.fedoraproject.org", directoryPath: "/pub/fedora/linux/releases/\(release)/Server/aarch64/iso/",
            iso: .newest(prefix: "Fedora-Server-netinst-aarch64-", suffix: ".iso"),
            checksum: .sharedPerRelease { "Fedora-Server-\($0)-aarch64-CHECKSUM" }, format: .bsd)
    }
}
