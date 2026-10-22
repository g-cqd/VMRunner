import Foundation
import RegexBuilder

/// A signed macOS restore image listed by ipsw.me.
struct IPSWFirmware: Codable, Identifiable, Hashable, Sendable {
    var version: String
    var buildid: String
    var url: URL
    var filesize: Int64
    var sha256sum: String?
    var signed: Bool

    var id: String { buildid }

    /// The SHA-256 ipsw.me lists, if it is exactly 64 lowercase hexadecimal digits.
    var checksum: Checksum? {
        guard let sha256sum, sha256sum.isLowercaseHexadecimal(digits: 64) else { return nil }
        return Checksum(algorithm: .sha256, value: sha256sum)
    }

    /// Whether the entry can be trusted to name a file the app may download: Apple's update server, a `.ipsw` name and a
    /// well-formed SHA-256. The catalog is a third party, so it is trusted for which builds exist, not for where they are.
    var isDownloadable: Bool { checksum != nil && (try? DownloadPolicy.validateRestoreImage(url)) != nil }

    var source: ImageSource { .remote(url, checksum: checksum) }

    var label: String {
        "macOS \(version) (\(buildid)) · \(ByteCountFormatter.string(fromByteCount: filesize, countStyle: .file))"
    }

    /// Virtualization.framework supports macOS 12 and later guests.
    var isGuestCapable: Bool {
        (Int(version.split(separator: ".").first ?? "") ?? 0) >= 12
    }
}

enum IPSWCatalog {
    private struct Response: Codable { var firmwares: [IPSWFirmware] }

    /// The Mac model identifier of this host (for example `Mac15,12`), or an empty string if it can't be read.
    static var hostModelIdentifier: String {
        var size = 0
        // The pointers passed to sysctl are to local variables that outlive each call, and the buffer is
        // sized by the first call before the second one fills it.
        guard unsafe sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard unsafe sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    /// Restore images are `UniversalMac_*`, so any Apple silicon identifier returns the same set.
    static func firmwares(for identifier: String) async throws -> [IPSWFirmware] {
        let model = try DownloadPolicy.validateMachineModel(identifier)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.ipsw.me"
        components.path = "/v4/device/\(model)"
        components.queryItems = [URLQueryItem(name: "type", value: "ipsw")]
        guard let url = components.url else { throw SetupError.invalidMachineModel(identifier) }
        return try decode(await Fetch.fetchSmall(url))
    }

    /// The signed, guest-capable builds whose file is on Apple's update server and has a SHA-256; any other entry is dropped.
    /// The SHA-256 ipsw.me lists for build `build`, if the file it lists has the name of `file`, the one Apple's own catalog
    /// named. Apple's catalog says where the file is; ipsw.me only supplies a second opinion on its hash.
    static func checksum(forBuild build: String, file: URL, in firmwares: [IPSWFirmware]) -> Checksum? {
        firmwares.first { $0.buildid == build && $0.url.lastPathComponent == file.lastPathComponent }?.checksum
    }

    static func decode(_ data: Data) throws -> [IPSWFirmware] {
        try JSONDecoder().decode(Response.self, from: data).firmwares.filter { $0.signed && $0.isGuestCapable && $0.isDownloadable }
    }
}

/// An installer image the app can download for a Linux guest (arm64 only: Apple silicon can't run x86_64 guests).
struct LinuxImage: Identifiable, Sendable {
    /// Stable across releases: it is stored in machine configurations as `ImageSource.linuxCatalog(id:)`.
    var id: String
    /// The distribution and release, for example `CentOS Stream 10`.
    var name: String
    /// The kind of image, for example `boot ISO`.
    var medium: String
    /// How the installer gets its packages, for example `network install`.
    var install: String
    /// A rough download size such as `~1 GB`.
    var approximateSize: String
    /// The most a download of this image may be, in bytes: a few times its size, so growth is tolerated and a stream that
    /// never ends is not.
    var maximumBytes: Int64
    /// Whether the installer's boot chain (shim) is signed so that it boots with Secure Boot on.
    var supportsSecureBoot: Bool
    /// One line on who publishes the image and what vouches for it.
    var trustNotes: String
    var provider: LinuxProvider

    var title: String { "\(name) · \(medium) (\(approximateSize), \(install))" }
}

enum LinuxCatalog {
    private static func centOS(_ release: Int, flavor: String, medium: String, install: String, size: String, maximumGiB: Int64)
        -> LinuxImage
    {
        LinuxImage(
            id: "centos-stream-\(release)-\(flavor)", name: "CentOS Stream \(release)", medium: medium, install: install,
            approximateSize: size, maximumBytes: maximumGiB << 30, supportsSecureBoot: true,
            trustNotes:
                "Published by the CentOS Project; the SHA-256 is fetched over HTTPS from the same mirror and is not separately signed.",
            provider: .centOSStream(release: release, flavor: flavor))
    }

    /// Images the app offers. Each one's host must be in `DownloadPolicy.allowedHosts`.
    static let images = [
        centOS(10, flavor: "boot", medium: "boot ISO", install: "network install", size: "~1 GB", maximumGiB: 4),
        centOS(9, flavor: "boot", medium: "boot ISO", install: "network install", size: "~1 GB", maximumGiB: 4),
        centOS(10, flavor: "dvd1", medium: "DVD", install: "offline install", size: "~9 GB", maximumGiB: 16),
        centOS(9, flavor: "dvd1", medium: "DVD", install: "offline install", size: "~9 GB", maximumGiB: 16),
        LinuxImage(
            id: "debian-stable-netboot-mini", name: "Debian stable", medium: "netboot mini ISO", install: "network install",
            approximateSize: "~200 MB", maximumBytes: 1 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the Debian Project on deb.debian.org; its SHA-256 index is covered by Debian's signed Release file, "
                + "which the app does not check.",
            provider: .debianNetbootMini),
        LinuxImage(
            id: "alpine-virt", name: "Alpine Linux", medium: "virt ISO", install: "diskless live system",
            approximateSize: "~93 MB", maximumBytes: 1 << 30, supportsSecureBoot: false,
            trustNotes: "Published by the Alpine Linux project. The ISO's detached OpenPGP signature (.asc) is checked against "
                + "the release signer's key built into the app; the SHA-256, fetched over HTTPS from the same server, is checked as well. "
                + "Releases older than 3.24.2, the oldest this version of the app accepts, are refused. Alpine publishes an ISO before its "
                + "signature: if the newest has none yet, the newest one that has is used and the setup says so; an image without a "
                + "signature is never used.",
            provider: .alpineVirt),
        LinuxImage(
            id: "ubuntu-server-26.04", name: "Ubuntu Server 26.04 LTS", medium: "live server ISO", install: "offline install",
            approximateSize: "~3 GB", maximumBytes: 8 << 30, supportsSecureBoot: true,
            trustNotes: "Published by Canonical. SHA256SUMS must carry a valid detached OpenPGP signature (SHA256SUMS.gpg) from "
                + "the Ubuntu CD image key built into the app, or the download is refused. Releases older than 26.04.1, the oldest "
                + "this version of the app accepts, are refused.",
            provider: .ubuntuServer(release: "26.04")),
        LinuxImage(
            id: "almalinux-10-boot", name: "AlmaLinux 10", medium: "boot ISO", install: "network install",
            approximateSize: "~1.1 GB", maximumBytes: 4 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the AlmaLinux OS Foundation. The CHECKSUM file must be an inline OpenPGP clear-signed message "
                + "made by the AlmaLinux 10 key built into the app, or the download is refused; releases older than 10.2 are refused.",
            provider: .almaLinux(release: 10, flavor: "boot")),
        LinuxImage(
            id: "almalinux-10-minimal", name: "AlmaLinux 10", medium: "minimal ISO", install: "offline install",
            approximateSize: "~1.7 GB", maximumBytes: 6 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the AlmaLinux OS Foundation. The CHECKSUM file must be an inline OpenPGP clear-signed message "
                + "made by the AlmaLinux 10 key built into the app, or the download is refused; releases older than 10.2 are refused.",
            provider: .almaLinux(release: 10, flavor: "minimal")),
        LinuxImage(
            id: "rocky-10-boot", name: "Rocky Linux 10", medium: "boot ISO", install: "network install",
            approximateSize: "~1.1 GB", maximumBytes: 4 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the Rocky Enterprise Software Foundation. The CHECKSUM file must carry a valid detached OpenPGP "
                + "signature (CHECKSUM.asc) from the Rocky Linux 10 key built into the app, or the download is refused; releases "
                + "older than 10.2 are refused.",
            provider: .rocky(release: 10, flavor: "boot")),
        LinuxImage(
            id: "rocky-10-minimal", name: "Rocky Linux 10", medium: "minimal ISO", install: "offline install",
            approximateSize: "~2.4 GB", maximumBytes: 8 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the Rocky Enterprise Software Foundation. The CHECKSUM file must carry a valid detached OpenPGP "
                + "signature (CHECKSUM.asc) from the Rocky Linux 10 key built into the app, or the download is refused; releases "
                + "older than 10.2 are refused.",
            provider: .rocky(release: 10, flavor: "minimal")),
        LinuxImage(
            id: "fedora-server-43-netinst", name: "Fedora Server 43", medium: "netinst ISO", install: "network install",
            approximateSize: "~1.2 GB", maximumBytes: 4 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the Fedora Project. The CHECKSUM file must be an inline OpenPGP clear-signed message made by "
                + "the Fedora 43 release key built into the app, or the download is refused; composes older than 43-1.6 are refused.",
            provider: .fedoraServerNetinst(release: 43)),
        LinuxImage(
            id: "fedora-server-44-netinst", name: "Fedora Server 44", medium: "netinst ISO", install: "network install",
            approximateSize: "~1.3 GB", maximumBytes: 4 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the Fedora Project. The CHECKSUM file must be an inline OpenPGP clear-signed message made by "
                + "the Fedora 44 release key built into the app, or the download is refused; composes older than 44-1.7 are refused.",
            provider: .fedoraServerNetinst(release: 44)),
    ]

    static func image(id: String) -> LinuxImage? { images.first { $0.id == id } }

    /// Verified providers that are deliberately not offered yet: each is one move into `images`, plus its host
    /// in `DownloadPolicy.allowedHosts`, away from being available.
    static let candidates = [
        LinuxImage(
            id: "debian-stable-netinst", name: "Debian stable", medium: "netinst ISO", install: "network install",
            approximateSize: "~700 MB", maximumBytes: 3 << 30, supportsSecureBoot: true,
            trustNotes: "Published by the Debian Project. SHA256SUMS must carry a valid detached OpenPGP signature (SHA256SUMS.sign) "
                + "from the Debian CD signing key built into the app; releases older than 13.7.0 are refused. "
                + "Blocked: the ISO download redirects to a third-party mirror, which the redirect policy refuses.",
            provider: .debianNetinst)
    ]

    /// Finds the newest ISO of `image` and its published SHA-256, and proves the checksum with whatever vouches for it.
    @concurrent
    static func resolve(_ image: LinuxImage) async throws -> ResolvedImage {
        try await image.provider.resolve()
    }
}
