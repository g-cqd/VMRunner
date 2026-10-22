import Foundation
import Testing

@testable import VMRunner

/// Real checksum files, trimmed to the lines that matter. No test here touches the network.
private enum Sample {
    static let centOS = """
        # CentOS-Stream-10-20261019.0-aarch64-boot.iso: 1026574336 bytes
        SHA256 (CentOS-Stream-10-20261019.0-aarch64-boot.iso) = 5ac47d11e9b4deb578f6c9fb0ba9b43f3ee19b3c3f8ce9c0b7b459ee4531c530
        """

    static let debianNetinst = "6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b  debian-13.7.0-arm64-netinst.iso\n"

    static let debianInstallerIndex = """
        bbe1f4dd6f2ce8ce8bb71b8fbbdfffe1b675648523eb968dd989066c73e41868  ./netboot/gtk/mini.iso
        7352cf14ab29a565c8c8b5089757882ce7fbbb06431973208c97ba51b6af6486  ./netboot/mini.iso
        """

    static let alpine = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6  alpine-virt-3.24.2-aarch64.iso\n"

    static let alma = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA256

        SHA256 (AlmaLinux-10.2-aarch64-boot.iso) = 20807d65338627a0afa3d5fbd3bee222115d66ce34ac1e4647b0af8fc6c4aa23
        SHA256 (AlmaLinux-10-latest-aarch64-boot.iso) = 20807d65338627a0afa3d5fbd3bee222115d66ce34ac1e4647b0af8fc6c4aa23
        SHA256 (AlmaLinux-10.2-aarch64-dvd.iso) = bc3790b1200254790e03f1d941162a9f9082d46dcdff841b83f348501625b29e
        SHA256 (AlmaLinux-10.2-aarch64-minimal.iso) = ca5dd9b7e1193de5881df850a93b611c6ba0ba8c5860f54ee822c53585b3014d
        -----BEGIN PGP SIGNATURE-----
        """

    static let rocky = """
        # Rocky-10.2-aarch64-boot.iso: 1120931840 bytes
        SHA256 (Rocky-10.2-aarch64-boot.iso) = 33c2d3dfd5f947b3201478180b549bb2995bd9573c2776b384e5ec1dd47326c0
        """

    static let ubuntu = """
        2ee2163c9b901ff5926400e80759088ff3b879982a3956c02100495b489fd555 *ubuntu-24.04.3-live-server-arm64.iso
        f12484464c7d4d73e2167e0a7dbda1e669f8fae9bcf778dc0944937034b320cb *ubuntu-24.04.5-live-server-arm64.iso
        5e83b9fb8b644b8c1d1087210ace05263170d2c29f72a1513afb21626204db36 *ubuntu-24.04.5-live-server-arm64+largemem.iso
        """

    static let fedora = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA256

        # Fedora-Server-dvd-aarch64-44-1.7.iso: 3662544896 bytes
        SHA256 (Fedora-Server-dvd-aarch64-44-1.7.iso) = ba8372682294d0d76f79427cae1273d36891b192ac9bf0f0f9de4e97a7cbe218
        # Fedora-Server-netinst-aarch64-44-1.7.iso: 1257783296 bytes
        SHA256 (Fedora-Server-netinst-aarch64-44-1.7.iso) = a93ebd0322cda5a439039710b727ac1899a06e1c11876cfdf7f27c25b8262cc3
        -----BEGIN PGP SIGNATURE-----
        """
}

struct ChecksumParsingTests {
    typealias Format = LinuxProvider.ChecksumFormat

    @Test(arguments: [
        (
            Format.bsd, Sample.centOS, "CentOS-Stream-10-20261019.0-aarch64-boot.iso",
            "5ac47d11e9b4deb578f6c9fb0ba9b43f3ee19b3c3f8ce9c0b7b459ee4531c530"
        ),
        (.bsd, Sample.rocky, "Rocky-10.2-aarch64-boot.iso", "33c2d3dfd5f947b3201478180b549bb2995bd9573c2776b384e5ec1dd47326c0"),
        (
            .bsd, Sample.fedora, "Fedora-Server-netinst-aarch64-44-1.7.iso",
            "a93ebd0322cda5a439039710b727ac1899a06e1c11876cfdf7f27c25b8262cc3"
        ),
        (.gnu, Sample.debianNetinst, "debian-13.7.0-arm64-netinst.iso", "6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b"),
        (.gnu, Sample.alpine, "alpine-virt-3.24.2-aarch64.iso", "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"),
        (.gnu, Sample.ubuntu, "ubuntu-24.04.5-live-server-arm64.iso", "f12484464c7d4d73e2167e0a7dbda1e669f8fae9bcf778dc0944937034b320cb"),
    ])
    func readsTheDigestOfTheRequestedFile(format: Format, text: String, name: String, digest: String) {
        #expect(format.sha256(for: name, in: text) == digest)
    }

    @Test func picksTheRequestedLineOutOfAFileThatListsManyImages() {
        #expect(
            Format.bsd.sha256(for: "AlmaLinux-10.2-aarch64-minimal.iso", in: Sample.alma)
                == "ca5dd9b7e1193de5881df850a93b611c6ba0ba8c5860f54ee822c53585b3014d")
        #expect(
            Format.bsd.sha256(for: "AlmaLinux-10.2-aarch64-dvd.iso", in: Sample.alma)
                == "bc3790b1200254790e03f1d941162a9f9082d46dcdff841b83f348501625b29e")
    }

    @Test func aPathEntryMatchesOnlyItsOwnLine() {
        #expect(
            Format.gnu.sha256(for: "netboot/mini.iso", in: Sample.debianInstallerIndex)
                == "7352cf14ab29a565c8c8b5089757882ce7fbbb06431973208c97ba51b6af6486")
        #expect(
            Format.gnu.sha256(for: "netboot/gtk/mini.iso", in: Sample.debianInstallerIndex)
                == "bbe1f4dd6f2ce8ce8bb71b8fbbdfffe1b675648523eb968dd989066c73e41868")
        #expect(Format.gnu.sha256(for: "mini.iso", in: Sample.debianInstallerIndex) == nil)
    }

    @Test func neverFallsBackToAnotherFilesHash() {
        #expect(Format.bsd.sha256(for: "AlmaLinux-10.3-aarch64-boot.iso", in: Sample.alma) == nil)
        #expect(Format.bsd.sha256(for: "AlmaLinux-10.2-aarch64-boot.iso.manifest", in: Sample.alma) == nil)
        #expect(Format.gnu.sha256(for: "ubuntu-24.04.5-live-server-arm64+largemem.iso", in: Sample.debianNetinst) == nil)
        #expect(Format.gnu.sha256(for: "debian-13.7.0-arm64-netinst.iso", in: Sample.centOS) == nil)
        #expect(Format.bsd.sha256(for: "debian-13.7.0-arm64-netinst.iso", in: Sample.debianNetinst) == nil)
    }

    @Test func ignoresDigestsOfTheWrongLengthOrAlphabet() {
        let short = String(repeating: "a", count: 63)
        let long = String(repeating: "a", count: 65)
        let notHex = String(repeating: "g", count: 64)
        for digest in [short, long, notHex] {
            #expect(Format.gnu.sha256(for: "x.iso", in: "\(digest)  x.iso") == nil)
            #expect(Format.bsd.sha256(for: "x.iso", in: "SHA256 (x.iso) = \(digest)") == nil)
        }
    }

    @Test func returnsLowercaseAndToleratesWindowsLineEndings() {
        let upper = String(repeating: "AB", count: 32)
        #expect(Format.gnu.sha256(for: "x.iso", in: "\(upper)  x.iso\r\n") == String(repeating: "ab", count: 32))
        #expect(Format.bsd.sha256(for: "x.iso", in: "SHA256 (x.iso) = \(upper)\r\n") == String(repeating: "ab", count: 32))
    }
}

struct NewestReleaseTests {
    private func listing(_ names: [String]) -> String {
        names.map { "<a href=\"\($0)\">\($0)</a>" }.joined(separator: "\n")
    }

    private func newest(_ provider: LinuxProvider, among names: [String]) -> LinuxRelease? {
        guard case .newest(let prefix, let suffix) = provider.iso else { return nil }
        return LinuxProvider.newest(inListing: listing(names), prefix: prefix, suffix: suffix)
    }

    @Test func centOSPicksTheLatestBuildAndTheRequestedFlavor() {
        let names = [
            "CentOS-Stream-10-20261009.0-aarch64-boot.iso", "CentOS-Stream-10-20261019.0-aarch64-boot.iso",
            "CentOS-Stream-10-20261019.0-aarch64-boot.iso.SHA256SUM", "CentOS-Stream-10-20261019.0-aarch64-dvd1.iso",
            "CentOS-Stream-10-20261020.1-aarch64-dvd1.iso", "CentOS-Stream-10-latest-aarch64-boot.iso",
            "CentOS-Stream-9-20261030.0-aarch64-boot.iso",
        ]
        #expect(newest(.centOSStream(release: 10, flavor: "boot"), among: names)?.path == "CentOS-Stream-10-20261019.0-aarch64-boot.iso")
        #expect(newest(.centOSStream(release: 10, flavor: "dvd1"), among: names)?.path == "CentOS-Stream-10-20261020.1-aarch64-dvd1.iso")
    }

    @Test func centOSComparesTheBuildNumberNumerically() {
        let names = ["CentOS-Stream-10-20261019.2-aarch64-boot.iso", "CentOS-Stream-10-20261019.10-aarch64-boot.iso"]
        #expect(newest(.centOSStream(release: 10, flavor: "boot"), among: names)?.path == "CentOS-Stream-10-20261019.10-aarch64-boot.iso")
    }

    @Test func alpineSkipsPreReleasesEvenWhenTheyAreNewer() {
        let names = [
            "alpine-virt-3.24.0_rc1-aarch64.iso", "alpine-virt-3.24.0_rc2-aarch64.iso", "alpine-virt-3.24.0-aarch64.iso",
            "alpine-virt-3.24.2-aarch64.iso", "alpine-virt-3.24.2-aarch64.iso.sha256", "alpine-virt-3.25.0_rc1-aarch64.iso",
            "alpine-virt-3.25.0_beta2-aarch64.iso", "alpine-virt-3.25.0_alpha1-aarch64.iso", "alpine-standard-3.24.3-aarch64.iso",
            "alpine-virt-3.24.10-aarch64.iso.asc",
        ]
        let release = newest(.alpineVirt, among: names)
        #expect(release?.path == "alpine-virt-3.24.2-aarch64.iso")
        #expect(release?.version == "3.24.2")
    }

    @Test func alpineComparesComponentsNumerically() {
        let names = [
            "alpine-virt-3.9.6-aarch64.iso", "alpine-virt-3.24.0-aarch64.iso", "alpine-virt-3.24.10-aarch64.iso",
            "alpine-virt-3.24.2-aarch64.iso",
        ]
        #expect(newest(.alpineVirt, among: names)?.path == "alpine-virt-3.24.10-aarch64.iso")
    }

    @Test(arguments: ["boot", "minimal"])
    func almaLinuxAndRockyIgnoreLatestAliasesAndPreferTenTenOverTenTwo(flavor: String) {
        let alma =
            ["10.2", "10.10", "10.9"].map { "AlmaLinux-\($0)-aarch64-\(flavor).iso" } + ["AlmaLinux-10-latest-aarch64-\(flavor).iso"]
        let rocky = ["10.2", "10.10", "10.9"].map { "Rocky-\($0)-aarch64-\(flavor).iso" } + ["Rocky-10-latest-aarch64-\(flavor).iso"]
        #expect(newest(.almaLinux(release: 10, flavor: flavor), among: alma)?.path == "AlmaLinux-10.10-aarch64-\(flavor).iso")
        #expect(newest(.rocky(release: 10, flavor: flavor), among: rocky)?.path == "Rocky-10.10-aarch64-\(flavor).iso")
    }

    @Test func rockyDoesNotMixUpBootAndDvdFlavors() {
        let names = ["Rocky-10.2-aarch64-dvd1.iso", "Rocky-10.2-aarch64-boot.iso", "Rocky-10.2-aarch64-boot.iso.CHECKSUM"]
        #expect(newest(.rocky(release: 10, flavor: "boot"), among: names)?.path == "Rocky-10.2-aarch64-boot.iso")
        #expect(newest(.rocky(release: 10, flavor: "dvd"), among: names) == nil)
    }

    @Test func debianNetinstTakesTheNewestPointRelease() {
        let names = ["debian-13.7.0-arm64-netinst.iso", "debian-13.10.0-arm64-netinst.iso", "debian-edu-13.11.0-arm64-netinst.iso"]
        #expect(newest(.debianNetinst, among: names)?.path == "debian-13.10.0-arm64-netinst.iso")
    }

    @Test func ubuntuPrefersThePointReleaseAndSkipsLargemem() {
        let names = [
            "ubuntu-26.04-live-server-arm64.iso", "ubuntu-26.04.1-live-server-arm64.iso",
            "ubuntu-26.04.2-live-server-arm64+largemem.iso", "ubuntu-26.04.1-desktop-arm64.iso",
        ]
        #expect(newest(.ubuntuServer(release: "26.04"), among: names)?.path == "ubuntu-26.04.1-live-server-arm64.iso")
    }

    @Test func fedoraComparesTheComposeNumberNumericallyAndReportsItForTheChecksumName() throws {
        let names = [
            "Fedora-Server-netinst-aarch64-44-1.7.iso", "Fedora-Server-netinst-aarch64-44-1.10.iso",
            "Fedora-Server-dvd-aarch64-44-1.11.iso",
        ]
        let provider = LinuxProvider.fedoraServerNetinst(release: 44)
        let release = try #require(newest(provider, among: names))
        #expect(release.path == "Fedora-Server-netinst-aarch64-44-1.10.iso")
        #expect(try provider.checksumURL(for: release).lastPathComponent == "Fedora-Server-44-1.10-aarch64-CHECKSUM")
    }

    @Test func returnsNilWhenNothingMatches() {
        #expect(newest(.alpineVirt, among: ["alpine-virt-3.24.0_rc1-aarch64.iso", "README.txt"]) == nil)
        #expect(LinuxProvider.newest(inListing: "", prefix: "x", suffix: "y") == nil)
    }

    @Test func releaseVersionsCompareNumerically() throws {
        let order = try ["9", "10", "10.2", "10.10", "10.10.1", "11"].map { try #require(ReleaseVersion($0)) }
        #expect(order == order.sorted())
        #expect(try #require(ReleaseVersion("26.04")) < #require(ReleaseVersion("26.04.1")))
        #expect(ReleaseVersion("") == nil)
        #expect(ReleaseVersion("3.24.0_rc2") == nil)
        #expect(ReleaseVersion("10..2") == nil)
    }
}

struct ProviderLocationTests {
    private func release(_ path: String, version: String = "") -> LinuxRelease { LinuxRelease(path: path, version: version) }

    @Test func siblingChecksumFilesSitNextToTheISO() throws {
        let centOS = LinuxProvider.centOSStream(release: 10, flavor: "boot")
        #expect(
            try centOS.checksumURL(for: release("CentOS-Stream-10-20261019.0-aarch64-boot.iso")).absoluteString
                == "https://mirror.stream.centos.org/10-stream/BaseOS/aarch64/iso/CentOS-Stream-10-20261019.0-aarch64-boot.iso.SHA256SUM")
        #expect(
            try LinuxProvider.alpineVirt.checksumURL(for: release("alpine-virt-3.24.2-aarch64.iso")).absoluteString
                == "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-virt-3.24.2-aarch64.iso.sha256")
    }

    @Test func sharedChecksumFilesLiveInTheDirectory() throws {
        #expect(
            try LinuxProvider.almaLinux(release: 10, flavor: "boot").checksumURL(for: release("AlmaLinux-10.2-aarch64-boot.iso"))
                .absoluteString
                == "https://repo.almalinux.org/almalinux/10/isos/aarch64/CHECKSUM")
        #expect(
            try LinuxProvider.debianNetinst.checksumURL(for: release("debian-13.7.0-arm64-netinst.iso")).absoluteString
                == "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS")
        #expect(
            try LinuxProvider.rocky(release: 10, flavor: "boot").checksumURL(for: release("Rocky-10.2-aarch64-boot.iso")).absoluteString
                == "https://download.rockylinux.org/pub/rocky/10/isos/aarch64/CHECKSUM")
    }

    @Test func theNetbootMiniISOIsAFixedPathWithItsIndexInTheParentDirectory() throws {
        let provider = LinuxProvider.debianNetbootMini
        guard case .fixed(let path) = provider.iso else {
            Issue.record("expected a fixed path")
            return
        }
        #expect(path == "netboot/mini.iso")
        #expect(
            try provider.directoryURL().appending(path: path).absoluteString
                == "https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/netboot/mini.iso")
        #expect(
            try provider.checksumURL(for: release(path)).absoluteString
                == "https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/SHA256SUMS")
    }
}

struct LinuxCatalogContentTests {
    private var everyImage: [LinuxImage] { LinuxCatalog.images + LinuxCatalog.candidates }

    @Test func idsAreUnique() {
        let ids = everyImage.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func legacyCentOSIdsStillResolve() {
        for id in ["centos-stream-10-boot", "centos-stream-9-boot", "centos-stream-10-dvd1", "centos-stream-9-dvd1"] {
            #expect(LinuxCatalog.images.contains { $0.id == id }, "\(id) is stored in users' machine configurations")
        }
    }

    @Test func titlesOfTheCentOSEntriesAreUnchanged() {
        let titles = LinuxCatalog.images.prefix(4).map(\.title)
        #expect(
            titles == [
                "CentOS Stream 10 · boot ISO (~1 GB, network install)", "CentOS Stream 9 · boot ISO (~1 GB, network install)",
                "CentOS Stream 10 · DVD (~9 GB, offline install)", "CentOS Stream 9 · DVD (~9 GB, offline install)",
            ])
    }

    @Test func aCandidateIsNeverAlsoOffered() {
        let offered = Set(LinuxCatalog.images.map(\.id))
        #expect(LinuxCatalog.candidates.allSatisfy { !offered.contains($0.id) })
    }

    @Test func everyOfferedImageStaysInsideTheDownloadPolicy() throws {
        for image in LinuxCatalog.images {
            let provider = image.provider
            let directory = try provider.directoryURL()
            _ = try DownloadPolicy.validate(directory)
            let path: String
            switch provider.iso {
            case .fixed(let fixed): path = fixed
            case .newest: path = "x-1.0.iso"
            }
            _ = try DownloadPolicy.validate(directory.appending(path: path))
            _ = try DownloadPolicy.validate(try provider.checksumURL(for: LinuxRelease(path: path, version: "1.0")))
        }
    }

    @Test func candidatesStayBlockedUntilTheirHostIsAllowed() throws {
        let hosts = Set(LinuxCatalog.candidates.compactMap { try? $0.provider.directoryURL().host() })
        #expect(hosts.contains("repo.almalinux.org"))
        for host in hosts where !host.hasSuffix("debian.org") {
            #expect(throws: SetupError.self, "\(host) is not approved yet") {
                try DownloadPolicy.validate(try #require(URL(string: "https://\(host)/x.iso")))
            }
        }
    }

    @Test func descriptionsAreFilledIn() {
        for image in everyImage {
            #expect(!image.name.isEmpty && !image.approximateSize.isEmpty && !image.trustNotes.isEmpty, "\(image.id)")
            #expect(!image.trustNotes.contains("\n"), "\(image.id) trust notes are one line")
            #expect(image.approximateSize.hasPrefix("~"), "\(image.id)")
        }
    }

    @Test func onlyAlpineLacksSecureBootSupport() {
        let without = everyImage.filter { !$0.supportsSecureBoot }.map(\.id)
        #expect(without == ["alpine-virt"])
    }
}

struct DebianHostPolicyTests {
    @Test(arguments: [
        "https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/netboot/mini.iso",
        "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS",
    ])
    func allowsDebianHosts(url: String) throws {
        _ = try DownloadPolicy.validate(try #require(URL(string: url)))
    }

    @Test(arguments: [
        "https://debian.org.evil.com/mini.iso",  // suffix spoof
        "https://notdebian.org/mini.iso",  // no dot boundary
        "https://evil.com/deb.debian.org/mini.iso",  // host in the path
        "https://deb.debian.org@evil.com/mini.iso",  // host in the user info
        "https://evil.com/?h=deb.debian.org",
        "http://deb.debian.org/mini.iso",
        "https://user@deb.debian.org/mini.iso",
        "https://deb.debian.org:8443/mini.iso",
        "https://alpinelinux.org/a.iso",
        "https://repo.almalinux.org/a.iso",
        "https://download.rockylinux.org/a.iso",
        "https://dl.fedoraproject.org/a.iso",
        "https://chuangtzu.ftp.acc.umu.se/debian-cd/a.iso",  // the mirror cdimage.debian.org redirects to
        "https://debian.org/",  // the bare domain is not pinned
        "https://salsa.debian.org/user/project/-/raw/main/a.iso",  // hosts user content
        "https://people.debian.org/~someone/a.iso",
        "https://www.debian.org/a.iso",
    ])
    func rejectsEverythingElse(url: String) throws {
        let parsed = try #require(URL(string: url))
        #expect(throws: SetupError.self) { try DownloadPolicy.validate(parsed) }
    }

    @Test func rejectsNonASCIILookalikesInFileNamesAndModelIdentifiers() throws {
        #expect(throws: SetupError.self) {
            try DownloadPolicy.cacheFileName(for: try #require(URL(string: "https://deb.debian.org/%EF%BD%81.iso")))
        }
        #expect(throws: SetupError.self) { try DownloadPolicy.validateMachineModel("Mac14,\u{0661}\u{0665}") }
        #expect(throws: SetupError.self) {
            try DownloadPolicy.cacheFileName(for: try #require(URL(string: "https://deb.debian.org/\(String(repeating: "a", count: 201))")))
        }
        #expect(
            try DownloadPolicy.cacheFileName(for: try #require(URL(string: "https://deb.debian.org/\(String(repeating: "a", count: 200))")))
                .count == 200)
    }
}
