import Foundation
import Testing

@testable import VMRunner

struct VendorListingTests {
    private func newest(_ provider: LinuxProvider, in listing: String) -> LinuxRelease? {
        guard case .newest(let prefix, let suffix) = provider.iso else { return nil }
        return LinuxProvider.newest(inListing: listing, prefix: prefix, suffix: suffix)
    }

    @Test func alpinePicksTheNewestStableVirtISOOutOfTheRealListing() {
        let release = newest(.alpineVirt, in: VendorFiles.alpineListing)
        #expect(release == LinuxRelease(path: "alpine-virt-3.24.2-aarch64.iso", version: "3.24.2"))
    }

    @Test func alpineNeverPicksAReleaseCandidateOrAnotherFlavor() {
        let others = VendorFiles.alpineListing.split(separator: "\n").filter { $0.contains("_rc") || $0.contains("alpine-standard") }
        #expect(newest(.alpineVirt, in: others.joined(separator: "\n")) == nil)
    }

    @Test func ubuntuPicksTheNewestPointReleaseOfTheStandardServerImageOutOfTheRealListing() {
        let release = newest(.ubuntuServer(release: "26.04"), in: VendorFiles.ubuntuListing)
        #expect(release == LinuxRelease(path: "ubuntu-26.04.1-live-server-arm64.iso", version: "26.04.1"))
    }

    @Test func ubuntuIgnoresTheLargememVariantAndOtherArchitectures() {
        let withoutStandard = VendorFiles.ubuntuListing.split(separator: "\n").filter { !$0.contains("live-server-arm64.iso\"") }
        #expect(newest(.ubuntuServer(release: "26.04"), in: withoutStandard.joined(separator: "\n")) == nil)
    }

    @Test func eachProviderResolvesFromItsListingAndChecksumFile() throws {
        let alpine = try #require(newest(.alpineVirt, in: VendorFiles.alpineListing))
        let ubuntuProvider = LinuxProvider.ubuntuServer(release: "26.04")
        let ubuntu = try #require(newest(ubuntuProvider, in: VendorFiles.ubuntuListing))

        let alpineSource = try LinuxProvider.alpineVirt.source(for: alpine, checksumText: VendorFiles.alpineChecksum)
        let ubuntuSource = try ubuntuProvider.source(for: ubuntu, checksumText: VendorFiles.ubuntuChecksums)

        guard case .remote(let alpineURL, let alpineSum?) = alpineSource, case .remote(let ubuntuURL, let ubuntuSum?) = ubuntuSource
        else {
            Issue.record("expected remote images with checksums")
            return
        }
        #expect(alpineURL.lastPathComponent == "alpine-virt-3.24.2-aarch64.iso")
        #expect(alpineSum.value == "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6")
        #expect(ubuntuURL.lastPathComponent == "ubuntu-26.04.1-live-server-arm64.iso")
        #expect(ubuntuSum.value == "af78753c94b924c85c4964c670692a853f7c80299a4064e317edad95462e3168")
        #expect(alpineSum.algorithm == .sha256 && ubuntuSum.algorithm == .sha256)
    }
}

struct VendorRegistrationTests {
    private func image(_ id: String) throws -> LinuxImage {
        try #require(LinuxCatalog.images.first { $0.id == id }, "\(id) is offered")
    }

    @Test func alpineAndUbuntuAreOfferedAndNoLongerCandidates() throws {
        for id in ["alpine-virt", "ubuntu-server-26.04"] {
            _ = try image(id)
            #expect(!LinuxCatalog.candidates.contains { $0.id == id })
        }
    }

    @Test func theOfferedUbuntuIsALongTermSupportRelease() throws {
        let ubuntu = try image("ubuntu-server-26.04")
        // /ubuntu/releases/<release>/release/: an LTS is the April release of an even year.
        let release = try #require(ubuntu.provider.directoryPath.split(separator: "/").dropFirst(2).first)
        let parts = release.split(separator: ".")
        #expect(parts.count == 2 && parts[1] == "04" && Int(parts[0])?.isMultiple(of: 2) == true, "\(release)")
        #expect(ubuntu.name.contains("LTS"))
    }

    @Test func alpineIsTheOnlyOfferedImageThatCannotUseSecureBoot() {
        #expect(LinuxCatalog.images.filter { !$0.supportsSecureBoot }.map(\.id) == ["alpine-virt"])
    }
}

struct VendorHostPolicyTests {
    @Test(arguments: [
        "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-virt-3.24.2-aarch64.iso",
        "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-virt-3.24.2-aarch64.iso.sha256",
        "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-live-server-arm64.iso",
        "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/SHA256SUMS",
    ])
    func allowsTheExactVendorHosts(url: String) throws {
        _ = try DownloadPolicy.validate(try #require(URL(string: url)))
    }

    @Test(arguments: [
        "https://alpinelinux.org/a.iso",  // the project's other hosts are not approved
        "https://mirror.alpinelinux.org/a.iso",
        "https://dl-cdn.alpinelinux.org.evil.example.com/a.iso",  // suffix spoof
        "https://evil-dl-cdn.alpinelinux.org/a.iso",  // no dot boundary
        "https://evil.example.com/dl-cdn.alpinelinux.org/a.iso",  // host in the path
        "https://dl-cdn.alpinelinux.org@evil.example.com/a.iso",  // host in the user info
        "http://dl-cdn.alpinelinux.org/a.iso",
        "https://dl-cdn.alpinelinux.org:8443/a.iso",
        "https://ubuntu.com/a.iso",
        "https://releases.ubuntu.com/a.iso",
        "https://archive.ubuntu.com/a.iso",
        "https://cdimage.ubuntu.com.evil.example.com/a.iso",
        "https://notcdimage.ubuntu.com/a.iso",
        "https://cdimage.ubuntu.com@evil.example.com/a.iso",
        "https://user@cdimage.ubuntu.com/a.iso",
        "http://cdimage.ubuntu.com/a.iso",
    ])
    func rejectsEverythingElse(url: String) throws {
        let parsed = try #require(URL(string: url))
        #expect(throws: SetupError.self) { try DownloadPolicy.validate(parsed) }
    }

    @Test func aRedirectOffTheListIsNotFollowed() throws {
        let path = "ubuntu/releases/26.04/release/SHA256SUMS"
        let mirror = URLRequest(url: try #require(URL(string: "https://mirror.example.net/\(path)")))
        let plain = URLRequest(url: try #require(URL(string: "http://cdimage.ubuntu.com/\(path)")))
        let same = URLRequest(url: try #require(URL(string: "https://cdimage.ubuntu.com/\(path)")))
        #expect(RedirectPolicy.allowed(mirror) == nil)
        #expect(RedirectPolicy.allowed(plain) == nil)
        #expect(RedirectPolicy.allowed(same) != nil)
    }
}
