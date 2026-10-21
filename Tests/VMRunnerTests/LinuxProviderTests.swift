import Foundation
import Testing

@testable import VMRunner

struct ChecksumSourceTests {
    private func release(_ path: String, version: String) -> LinuxRelease { LinuxRelease(path: path, version: version) }

    @Test func alpineSourceCarriesTheISOURLAndItsPublishedDigest() throws {
        let name = "alpine-virt-3.24.2-aarch64.iso"
        let source = try LinuxProvider.alpineVirt.source(for: release(name, version: "3.24.2"), checksumText: VendorFiles.alpineChecksum)
        let url = try #require(URL(string: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/\(name)"))
        let digest = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"
        #expect(source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
    }

    @Test func ubuntuSourceTakesTheStandardServerImageNotTheLargememOne() throws {
        let provider = LinuxProvider.ubuntuServer(release: "26.04")
        let standard = try provider.source(
            for: release("ubuntu-26.04.1-live-server-arm64.iso", version: "26.04.1"), checksumText: VendorFiles.ubuntuChecksums)
        let largemem = try provider.source(
            for: release("ubuntu-26.04.1-live-server-arm64+largemem.iso", version: "26.04.1"), checksumText: VendorFiles.ubuntuChecksums)
        let url = try #require(
            URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-live-server-arm64.iso"))
        let digest = "af78753c94b924c85c4964c670692a853f7c80299a4064e317edad95462e3168"
        #expect(standard == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
        #expect(standard != largemem)
    }

    @Test(arguments: [
        "",
        "\n\n",
        "<html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>",
        "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf  alpine-virt-3.24.2-aarch64.iso",  // 63 digits
        "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6 alpine-virt-3.24.2-aarch64.iso",  // one space
        "alpine-virt-3.24.2-aarch64.iso a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6",  // swapped
        "-----BEGIN PGP SIGNATURE-----\n\niQEzBAEBCAAdFiEE\n-----END PGP SIGNATURE-----",
        "\u{0}\u{1}\u{2}\u{FFFD}",
    ])
    func aMalformedChecksumFileYieldsNoDigest(text: String) {
        let provider = LinuxProvider.alpineVirt
        #expect {
            try provider.source(for: release("alpine-virt-3.24.2-aarch64.iso", version: "3.24.2"), checksumText: text)
        } throws: { error in
            guard case SetupError.missingFile(let what) = error else { return false }
            return what == "the SHA-256 of alpine-virt-3.24.2-aarch64.iso in alpine-virt-3.24.2-aarch64.iso.sha256"
        }
    }

    @Test func aWellFormedFileWithoutTheChosenReleaseYieldsNoDigest() {
        let provider = LinuxProvider.ubuntuServer(release: "26.04")
        #expect(throws: SetupError.self) {
            try provider.source(
                for: release("ubuntu-26.04.2-live-server-arm64.iso", version: "26.04.2"), checksumText: VendorFiles.ubuntuChecksums)
        }
    }

    @Test func aDownloadThatDiffersFromTheListedDigestIsRefused() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "alpine-virt-3.24.2-aarch64.iso"
        let file = directory.appending(path: name)
        try Data("an installer someone replaced".utf8).write(to: file)
        let source = try LinuxProvider.alpineVirt.source(for: release(name, version: "3.24.2"), checksumText: VendorFiles.alpineChecksum)
        guard case .remote(_, let checksum?) = source else {
            Issue.record("expected a remote image with a checksum")
            return
        }

        await #expect {
            try await Checksums.verify(file, against: checksum)
        } throws: { error in
            guard case SetupError.checksumMismatch(let refused, let expected, let actual) = error else { return false }
            return refused == name && expected == checksum.value && actual != expected
        }
    }

    @Test func aProviderOutsideTheAllowListIsRefusedBeforeAnyRequest() async {
        let provider = LinuxProvider(
            host: "downloads.example.com", directoryPath: "/alpine/", iso: .fixed(path: "alpine-virt-3.24.2-aarch64.iso"),
            checksum: .sibling(suffix: "sha256"), format: .gnu)
        await #expect {
            try await provider.resolve()
        } throws: { error in
            guard case SetupError.untrustedURL(let refused) = error else { return false }
            return refused.host() == "downloads.example.com"
        }
    }
}
