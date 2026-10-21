import Foundation
import Testing

@testable import VMRunner

/// Files the vendors publish, captured on 2026-10-21 and trimmed to the lines that matter. No test here touches the network.
private enum Fixture {
    /// `alpine-virt-3.24.2-aarch64.iso.sha256`, whole.
    static let alpineChecksum = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6  alpine-virt-3.24.2-aarch64.iso\n"

    /// `SHA256SUMS` of Ubuntu's 26.04 release directory, whole.
    static let ubuntuChecksums = """
        c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57 *ubuntu-26.04-desktop-arm64.iso
        d31e9b3d01ac0fa8e488d4f8d5a7acfeee869f387674eaedf94335e174155901 *ubuntu-26.04-live-server-arm64+largemem.iso
        c9aa567e6560b2eddae3af03fc686002e35b6fee96f97fd5df3271e846439fdd *ubuntu-26.04-live-server-arm64.iso
        0e9f326f55dcc4244f15336ca1221e6d2f36722a4954fc544570da0a12067c3e *ubuntu-26.04-live-server-ppc64el.iso
        82afc6b53c1009d6359017bc9522858670942746e8522d0d6ec951af828b919e *ubuntu-26.04-live-server-riscv64.iso
        d9da688f07bf7a32eba43ba517ce0d4ad19457163fc1f25ddd0d9c6b9dc29632 *ubuntu-26.04-live-server-s390x.iso
        c8b5d454baf26c6ed3f2a211cdd80183671aed8b67a92817cf5750e02da7f6a6 *ubuntu-26.04-preinstalled-desktop-arm64+raspi.img.xz
        17e3699da18dce8f91cdfef2cf4346d9b5c2d0a30e69fde3d3f0dec92490d1c8 *ubuntu-26.04-preinstalled-server-amd64.img.xz
        10604098a0c4eeb7359e58e12b01badbce8c74b0d53b414e633ba0b047b512cd *ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz
        aaa7431beb07aded27664c11c913a66b1764b54538967dfb8d2b3b34d961dd7e *ubuntu-26.04-preinstalled-server-arm64.img.xz
        42210dc700bd7967e7fe294f60d8ee643b27e5870b8f49a4d710155485258aae *ubuntu-26.04-preinstalled-server-riscv64.img.xz
        9fae7b65ac7be0ebb019987c922f1f1f1aaffb061834eb22e76a5e2a958dd3f6 *ubuntu-26.04-wsl-arm64.wsl
        c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517 *ubuntu-26.04.1-desktop-arm64.iso
        a7110f6c5e77e6f9d2dd1504a71c43d92c859fcee842bd0d51ca790e8afb5f21 *ubuntu-26.04.1-desktop-riscv64.iso
        2162508a288569897fd9035a6be206b16af9dee525ada692a43cecc9ae986797 *ubuntu-26.04.1-live-server-arm64+largemem.iso
        af78753c94b924c85c4964c670692a853f7c80299a4064e317edad95462e3168 *ubuntu-26.04.1-live-server-arm64.iso
        3eb24626add663104f416bbdb3ca6ed37eabf8bb9a2308d4c9751d0976094826 *ubuntu-26.04.1-live-server-ppc64el.iso
        c44c0e9343a477e08943a140d21ac903ec891ece5c0a69f7424e198562f9f272 *ubuntu-26.04.1-live-server-riscv64.iso
        3756e8b969f67b59e85104cbabe5e1d86e02feb3835a90f6ea97ace86845b49a *ubuntu-26.04.1-live-server-s390x.iso
        8216f54cc1df2fcf7de37530a7edccdd200abd7dcfbc5d4f0407df7513544d6a *ubuntu-26.04.1-preinstalled-desktop-arm64+raspi.img.xz
        80c3b730202a1b02997950d3b08f519550ae97042be9d318ccb5f01cc56c2137 *ubuntu-26.04.1-preinstalled-server-amd64.img.xz
        d59ef9c6e85b906995501f166d00726ab80b59be7b65cdeac0fa31b996053e13 *ubuntu-26.04.1-preinstalled-server-arm64+raspi.img.xz
        189b1aec3eaf9544a51dba4e6ac3f4d5d24fd1031ed0263fa5ea78f1824934c1 *ubuntu-26.04.1-preinstalled-server-arm64.img.xz
        0fafe15634d3b66c3fcb4df17a5fde0b340d2d663af47e4fb5ffb59b9dddc94a *ubuntu-26.04.1-preinstalled-server-riscv64.img.xz
        c7d893d7ccb291009e6096c5a946937337b6fd4c426f11b6541f6cd2bf894f7d *ubuntu-26.04.1-wsl-arm64.wsl

        """
}

struct ChecksumSourceTests {
    private func release(_ path: String, version: String) -> LinuxRelease { LinuxRelease(path: path, version: version) }

    @Test func alpineSourceCarriesTheISOURLAndItsPublishedDigest() throws {
        let name = "alpine-virt-3.24.2-aarch64.iso"
        let source = try LinuxProvider.alpineVirt.source(for: release(name, version: "3.24.2"), checksumText: Fixture.alpineChecksum)
        let url = try #require(URL(string: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/\(name)"))
        let digest = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"
        #expect(source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
    }

    @Test func ubuntuSourceTakesTheStandardServerImageNotTheLargememOne() throws {
        let provider = LinuxProvider.ubuntuServer(release: "26.04")
        let standard = try provider.source(
            for: release("ubuntu-26.04.1-live-server-arm64.iso", version: "26.04.1"), checksumText: Fixture.ubuntuChecksums)
        let largemem = try provider.source(
            for: release("ubuntu-26.04.1-live-server-arm64+largemem.iso", version: "26.04.1"), checksumText: Fixture.ubuntuChecksums)
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
                for: release("ubuntu-26.04.2-live-server-arm64.iso", version: "26.04.2"), checksumText: Fixture.ubuntuChecksums)
        }
    }

    @Test func aDownloadThatDiffersFromTheListedDigestIsRefused() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "alpine-virt-3.24.2-aarch64.iso"
        let file = directory.appending(path: name)
        try Data("an installer someone replaced".utf8).write(to: file)
        let source = try LinuxProvider.alpineVirt.source(for: release(name, version: "3.24.2"), checksumText: Fixture.alpineChecksum)
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
