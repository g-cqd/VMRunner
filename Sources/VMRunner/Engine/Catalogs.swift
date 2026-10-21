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

    var checksum: Checksum? { sha256sum.map { Checksum(algorithm: .sha256, value: $0) } }

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
        return try decode(await Network.fetchSmall(url))
    }

    static func decode(_ data: Data) throws -> [IPSWFirmware] {
        try JSONDecoder().decode(Response.self, from: data).firmwares.filter { $0.signed && $0.isGuestCapable }
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
    /// Whether the installer's boot chain (shim) is signed so that it boots with Secure Boot on.
    var supportsSecureBoot: Bool
    /// One line on who publishes the image and what vouches for it.
    var trustNotes: String
    var provider: LinuxProvider

    var title: String { "\(name) · \(medium) (\(approximateSize), \(install))" }
}

enum LinuxCatalog {
    private static func centOS(_ release: Int, flavor: String, medium: String, install: String, size: String) -> LinuxImage {
        LinuxImage(
            id: "centos-stream-\(release)-\(flavor)", name: "CentOS Stream \(release)", medium: medium, install: install,
            approximateSize: size, supportsSecureBoot: true,
            trustNotes:
                "Published by the CentOS Project; the SHA-256 is fetched over HTTPS from the same mirror and is not separately signed.",
            provider: .centOSStream(release: release, flavor: flavor))
    }

    /// Images the app offers. Each one's host must be in `DownloadPolicy.allowedHostSuffixes`.
    static let images = [
        centOS(10, flavor: "boot", medium: "boot ISO", install: "network install", size: "~1 GB"),
        centOS(9, flavor: "boot", medium: "boot ISO", install: "network install", size: "~1 GB"),
        centOS(10, flavor: "dvd1", medium: "DVD", install: "offline install", size: "~9 GB"),
        centOS(9, flavor: "dvd1", medium: "DVD", install: "offline install", size: "~9 GB"),
        LinuxImage(
            id: "debian-stable-netboot-mini", name: "Debian stable", medium: "netboot mini ISO", install: "network install",
            approximateSize: "~200 MB", supportsSecureBoot: true,
            trustNotes:
                "Published by the Debian Project on deb.debian.org; its SHA-256 index is covered by Debian's signed Release file.",
            provider: .debianNetbootMini),
    ]

    /// Verified providers that are deliberately not offered yet: each is one move into `images`, plus its host
    /// in `DownloadPolicy.allowedHostSuffixes`, away from being available.
    static let candidates = [
        LinuxImage(
            id: "debian-stable-netinst", name: "Debian stable", medium: "netinst ISO", install: "network install",
            approximateSize: "~700 MB", supportsSecureBoot: true,
            trustNotes: "Published by the Debian Project; SHA256SUMS has a detached OpenPGP signature (SHA256SUMS.sign). "
                + "Blocked: the ISO download redirects to a third-party mirror, which the redirect policy refuses.",
            provider: .debianNetinst),
        LinuxImage(
            id: "alpine-virt", name: "Alpine Linux", medium: "virt ISO", install: "diskless live system",
            approximateSize: "~93 MB", supportsSecureBoot: false,
            trustNotes:
                "Published by the Alpine Linux project; the ISO has a detached OpenPGP signature (.asc), its checksum file has none.",
            provider: .alpineVirt),
        LinuxImage(
            id: "almalinux-10-boot", name: "AlmaLinux 10", medium: "boot ISO", install: "network install",
            approximateSize: "~1.1 GB", supportsSecureBoot: true,
            trustNotes: "Published by the AlmaLinux OS Foundation; the CHECKSUM file is an inline OpenPGP clear-signed message.",
            provider: .almaLinux(release: 10, flavor: "boot")),
        LinuxImage(
            id: "almalinux-10-minimal", name: "AlmaLinux 10", medium: "minimal ISO", install: "offline install",
            approximateSize: "~1.7 GB", supportsSecureBoot: true,
            trustNotes: "Published by the AlmaLinux OS Foundation; the CHECKSUM file is an inline OpenPGP clear-signed message.",
            provider: .almaLinux(release: 10, flavor: "minimal")),
        LinuxImage(
            id: "rocky-10-boot", name: "Rocky Linux 10", medium: "boot ISO", install: "network install",
            approximateSize: "~1.1 GB", supportsSecureBoot: true,
            trustNotes:
                "Published by the Rocky Enterprise Software Foundation; each .CHECKSUM file has a detached OpenPGP signature (.asc).",
            provider: .rocky(release: 10, flavor: "boot")),
        LinuxImage(
            id: "rocky-10-minimal", name: "Rocky Linux 10", medium: "minimal ISO", install: "offline install",
            approximateSize: "~2.4 GB", supportsSecureBoot: true,
            trustNotes:
                "Published by the Rocky Enterprise Software Foundation; each .CHECKSUM file has a detached OpenPGP signature (.asc).",
            provider: .rocky(release: 10, flavor: "minimal")),
        LinuxImage(
            id: "ubuntu-server-26.04", name: "Ubuntu Server 26.04 LTS", medium: "live server ISO", install: "offline install",
            approximateSize: "~3 GB", supportsSecureBoot: true,
            trustNotes: "Published by Canonical; SHA256SUMS has a detached OpenPGP signature (SHA256SUMS.gpg).",
            provider: .ubuntuServer(release: "26.04")),
        LinuxImage(
            id: "fedora-server-44-netinst", name: "Fedora Server 44", medium: "netinst ISO", install: "network install",
            approximateSize: "~1.3 GB", supportsSecureBoot: true,
            trustNotes: "Published by the Fedora Project; the CHECKSUM file is an inline OpenPGP clear-signed message.",
            provider: .fedoraServerNetinst(release: 44)),
    ]

    /// Finds the newest ISO of `image` and its published SHA-256.
    static func resolve(_ image: LinuxImage) async throws -> ImageSource {
        try await image.provider.resolve()
    }
}
