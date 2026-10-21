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

/// A pattern compiled once and shared by every caller.
struct SharedPattern<Output>: @unchecked Sendable {  // a compiled Regex is never mutated; matching only reads it
    let regex: Regex<Output>

    init(_ regex: Regex<Output>) { self.regex = regex }
}

/// An installer ISO chosen from a provider: its path relative to the provider's directory and its release number.
struct LinuxRelease: Equatable, Sendable {
    /// For example `debian-13.7.0-arm64-netinst.iso` or `netboot/mini.iso`. Never contains a `..` component.
    var path: String
    /// The release text the file name carries (`13.7.0`); empty for a fixed path.
    var version: String
}

/// What `LinuxProvider.resolve` found: where the installer is, the checksum it must have, and, when the vendor signs the
/// installer itself, the signature to check once it is downloaded.
struct ResolvedImage: Sendable {
    var source: ImageSource
    var imageSignature: PGP.Check?
}

/// How one distribution publishes an installer ISO and its SHA-256: where to look, which file is the newest,
/// how to read the checksum, and what vouches for it. Adding a distribution means describing it here, not writing new
/// fetch code.
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

        /// The most lines of a checksum file that are read. The files the vendors publish list tens of images; a file with
        /// more is not one of them, and reading all of it would only spend time.
        static let maximumLines = 10_000

        /// The longest line that is read, in bytes. A checksum line is a digest and a file name.
        static let maximumLineLength = 1024

        // The patterns are built once: a pattern built per line costs far more than matching it.
        private static let bsdLine = SharedPattern(
            Regex {
                "SHA256 ("
                Capture { OneOrMore(.anyOf(")").inverted) }
                ") = "
                Capture { Repeat(count: 64) { .asciiHexDigit } }
                ZeroOrMore(.horizontalWhitespace)
            })

        private static let gnuLine = SharedPattern(
            Regex {
                Capture { Repeat(count: 64) { .asciiHexDigit } }
                " "
                ChoiceOf {
                    " "
                    "*"
                }
                Optionally("./")
                Capture { OneOrMore(.whitespace.inverted) }
                ZeroOrMore(.horizontalWhitespace)
            })

        /// The lowercase SHA-256 on the line that names exactly `entry`, byte for byte, or nil if no line does. Other
        /// lines, comments and signature armor are ignored, so a file that lists many images can't
        /// supply another image's hash. Only the first `maximumLines` lines are read, and a line longer than
        /// `maximumLineLength` bytes is skipped.
        func sha256(for entry: String, in text: String) -> String? {
            let lines = text.utf8.split(maxSplits: Self.maximumLines, omittingEmptySubsequences: true) { $0 == 0x0A || $0 == 0x0D }
            for bytes in lines.prefix(Self.maximumLines) where bytes.count <= Self.maximumLineLength {
                let line = Substring(bytes)
                let named: (name: Substring, digest: Substring)?
                switch self {
                case .bsd: named = line.wholeMatch(of: Self.bsdLine.regex).map { ($0.output.1, $0.output.2) }
                case .gnu: named = line.wholeMatch(of: Self.gnuLine.regex).map { ($0.output.2, $0.output.1) }
                }
                if let named, named.name.utf8.elementsEqual(entry.utf8) { return named.digest.lowercased() }
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
    /// What vouches for the checksum file. Every provider states it: `HTTPSOnlyTrust` is a choice, not a default.
    var trust: any ChecksumTrust

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

    private static let hrefAttribute = SharedPattern(
        Regex {
            "href=\""
            Capture { OneOrMore(.anyOf("\"").inverted) }
            "\""
        })

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
        let names = Set(listing.matches(of: Self.hrefAttribute.regex).map { String($0.output.1) })
        let candidates = names.compactMap { name -> (release: LinuxRelease, version: ReleaseVersion)? in
            // The listing is unsigned input: a name that is not plain ASCII is never one of the vendor's files.
            guard name.utf8.allSatisfy({ $0 < 0x80 }), let match = name.wholeMatch(of: matcher),
                let version = ReleaseVersion(match.output.1)
            else { return nil }
            return (LinuxRelease(path: name, version: String(match.output.1)), version)
        }
        return candidates.max { $0.version < $1.version }?.release
    }

    /// Finds the newest ISO and its published SHA-256, and proves the checksum file with `trust` before reading it.
    ///
    /// This runs off the calling actor: it reads megabytes of listing and checksum text and verifies signatures, none of
    /// which may stall the interface.
    /// - Parameters:
    ///   - now: The time signatures are judged by.
    ///   - fetch: How the listing, the checksum file and signatures are downloaded.
    /// - Returns: The installer's location and checksum, and its signature when the vendor signs the installer itself.
    /// - Throws: `SetupError` if the directory has no matching ISO, the checksum file has no line for it, or the trust the
    ///   provider relies on refuses it (`SetupError.signatureRejected`).
    @concurrent
    func resolve(now: Date = Date(), fetch: SmallFetch = { try await Network.fetchSmall($0, limit: $1) }) async throws -> ResolvedImage {
        let directory = try directoryURL()
        let release: LinuxRelease
        switch iso {
        case .fixed(let path):
            release = LinuxRelease(path: path, version: "")
        case .newest(let prefix, let suffix):
            let listing = try Self.text(of: try await fetch(directory, Network.smallLimit), at: directory)
            guard let newest = Self.newest(inListing: listing, prefix: prefix, suffix: suffix) else {
                throw SetupError.missingFile("a matching ISO in \(directory)")
            }
            release = newest
        }
        let checksumURL = try checksumURL(for: release)
        let file = try await fetch(checksumURL, Network.smallLimit)
        let vouched = try await trust.vouch(
            for: file, at: checksumURL, image: directory.appending(path: release.path), now: now, fetch: fetch)
        return ResolvedImage(source: try source(for: release, checksumText: vouched.text), imageSignature: vouched.imageSignature)
    }

    /// `release` as a remote image with the SHA-256 that `checksumText` lists for exactly that file.
    /// - Throws: `SetupError` if the text has no line for it; a malformed file has none.
    func source(for release: LinuxRelease, checksumText: String) throws(SetupError) -> ImageSource {
        guard let digest = format.sha256(for: release.path, in: checksumText) else {
            throw .missingFile("the SHA-256 of \(release.path) in \(try checksumURL(for: release).lastPathComponent)")
        }
        return .remote(try directoryURL().appending(path: release.path), checksum: Checksum(algorithm: .sha256, value: digest))
    }

    /// The UTF-8 text of a downloaded document.
    static func text(of data: Data, at url: URL) throws(SetupError) -> String {
        guard let text = String(bytes: data, encoding: .utf8) else { throw .missingFile("readable text at \(url)") }
        return text
    }
}

// MARK: Distributions

extension LinuxProvider {
    static func centOSStream(release: Int, flavor: String) -> Self {
        Self(
            host: "mirror.stream.centos.org", directoryPath: "/\(release)-stream/BaseOS/aarch64/iso/",
            iso: .newest(prefix: "CentOS-Stream-\(release)-", suffix: "-aarch64-\(flavor).iso"),
            checksum: .sibling(suffix: "SHA256SUM"), format: .bsd, trust: HTTPSOnlyTrust())
    }

    /// `SHA256SUMS` is signed by the Debian CD signing key (`SHA256SUMS.sign`).
    static let debianNetinst = Self(
        host: "cdimage.debian.org", directoryPath: "/debian-cd/current/arm64/iso-cd/",
        iso: .newest(prefix: "debian-", suffix: "-arm64-netinst.iso"),
        checksum: .shared(fileName: "SHA256SUMS"), format: .gnu,
        trust: SignedChecksumTrust(placement: .detached(suffix: "sign"), keys: [PGP.PinnedKeys.debianCD]))

    /// This index is covered by Debian's signed Release file, not by a signature of its own, so it is trusted for its host only.
    static let debianNetbootMini = Self(
        host: "deb.debian.org", directoryPath: "/debian/dists/stable/main/installer-arm64/current/images/",
        iso: .fixed(path: "netboot/mini.iso"), checksum: .shared(fileName: "SHA256SUMS"), format: .gnu, trust: HTTPSOnlyTrust())

    /// The `.sha256` beside an ISO is not signed; the ISO's own signature (`.asc`) is checked after the download.
    static let alpineVirt = Self(
        host: "dl-cdn.alpinelinux.org", directoryPath: "/alpine/latest-stable/releases/aarch64/",
        iso: .newest(prefix: "alpine-virt-", suffix: "-aarch64.iso"),
        checksum: .sibling(suffix: "sha256"), format: .gnu,
        trust: SignedImageTrust(suffix: "asc", keys: [PGP.PinnedKeys.alpineCopa]))

    static func almaLinux(release: Int, flavor: String) -> Self {
        Self(
            host: "repo.almalinux.org", directoryPath: "/almalinux/\(release)/isos/aarch64/",
            iso: .newest(prefix: "AlmaLinux-", suffix: "-aarch64-\(flavor).iso"),
            checksum: .shared(fileName: "CHECKSUM"), format: .bsd, trust: HTTPSOnlyTrust())
    }

    static func rocky(release: Int, flavor: String) -> Self {
        Self(
            host: "download.rockylinux.org", directoryPath: "/pub/rocky/\(release)/isos/aarch64/",
            iso: .newest(prefix: "Rocky-", suffix: "-aarch64-\(flavor).iso"),
            checksum: .sibling(suffix: "CHECKSUM"), format: .bsd, trust: HTTPSOnlyTrust())
    }

    /// The live-server installer of an Ubuntu release such as `26.04`; its point releases (`26.04.1`) share the directory.
    static func ubuntuServer(release: String) -> Self {
        Self(
            host: "cdimage.ubuntu.com", directoryPath: "/ubuntu/releases/\(release)/release/",
            iso: .newest(prefix: "ubuntu-", suffix: "-live-server-arm64.iso"),
            checksum: .shared(fileName: "SHA256SUMS"), format: .gnu,
            trust: SignedChecksumTrust(placement: .detached(suffix: "gpg"), keys: [PGP.PinnedKeys.ubuntuCDImage]))
    }

    /// The CHECKSUM file is a cleartext-signed message made by that release's Fedora key; a release the app pins no key for
    /// is refused, not read without a signature.
    static func fedoraServerNetinst(release: Int) -> Self {
        Self(
            host: "dl.fedoraproject.org", directoryPath: "/pub/fedora/linux/releases/\(release)/Server/aarch64/iso/",
            iso: .newest(prefix: "Fedora-Server-netinst-aarch64-", suffix: ".iso"),
            checksum: .sharedPerRelease { "Fedora-Server-\($0)-aarch64-CHECKSUM" }, format: .bsd,
            trust: SignedChecksumTrust(placement: .cleartext, keys: PGP.PinnedKeys.fedora(release: release)))
    }
}
