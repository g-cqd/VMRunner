import Foundation
import Testing

@testable import VMRunner

private let almaDirectory = "https://repo.almalinux.org/almalinux/10/isos/aarch64/"

/// AlmaLinux signs one CHECKSUM list per major version inline (a cleartext-signed message), with one key per major version.
struct AlmaLinuxProviderTests {
    @Test func theRealChecksumFileVerifiesAgainstThePinnedKeyAndYieldsOnlyTheSignedText() throws {
        let text = try PGP.Check.verifyClearSigned(
            Array(SignedVendorFiles.almaLinuxChecksum.utf8), keys: [PGP.PinnedKeys.almaLinux10.publicKey()], now: pgpGoldenNow)
        let lines = utf8String(text).split(separator: "\n")
        #expect(lines.count == 12)
        #expect(
            lines.contains(
                "SHA256 (AlmaLinux-10.2-aarch64-boot.iso) = 20807d65338627a0afa3d5fbd3bee222115d66ce34ac1e4647b0af8fc6c4aa23"))
    }

    @Test(arguments: [
        ("boot", "20807d65338627a0afa3d5fbd3bee222115d66ce34ac1e4647b0af8fc6c4aa23"),
        ("minimal", "ca5dd9b7e1193de5881df850a93b611c6ba0ba8c5860f54ee822c53585b3014d"),
    ])
    func theNewestISOIsChosenFromTheSignedListAlone(flavor: String, digest: String) async throws {
        let mirror = FixtureMirror([almaDirectory + "CHECKSUM": SignedVendorFiles.almaLinuxChecksum])
        let resolved = try await LinuxProvider.almaLinux(release: 10, flavor: flavor).resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        let url = try #require(URL(string: almaDirectory + "AlmaLinux-10.2-aarch64-\(flavor).iso"))
        #expect(resolved.source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
        #expect(resolved.version == "10.2")
        #expect(mirror.requests.map(\.url) == [almaDirectory + "CHECKSUM"], "the unsigned listing is not fetched")
    }

    @Test func aChecksumFileThatIsNotSignedIsRefused() async {
        let unsigned = "SHA256 (AlmaLinux-10.3-aarch64-boot.iso) = \(String(repeating: "ab", count: 32))\n"
        let mirror = FixtureMirror([almaDirectory + "CHECKSUM": unsigned])
        await #expect(throws: SetupError.self) {
            try await LinuxProvider.almaLinux(release: 10, flavor: "boot").resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        }
    }

    @Test func aMajorVersionWithoutAPinnedKeyIsRefusedNotReadUnsigned() async {
        let mirror = FixtureMirror(["https://repo.almalinux.org/almalinux/11/isos/aarch64/CHECKSUM": SignedVendorFiles.almaLinuxChecksum])
        await #expect(throws: SetupError.self) {
            try await LinuxProvider.almaLinux(release: 11, flavor: "boot").resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        }
    }
}

/// Rocky Linux signs one CHECKSUM list per major version with a detached signature, with one key per major version.
struct RockyLinuxProviderTests {
    @Test func theRealChecksumFileVerifiesAgainstThePinnedKey() throws {
        let check = try PGP.Check.detached(
            Array(SignedVendorFiles.rockyLinuxSignature.utf8), keys: [PGP.PinnedKeys.rockyLinux10.publicKey()], now: pgpGoldenNow)
        try check.verify(Array(SignedVendorFiles.rockyLinuxChecksum.utf8))
        #expect(throws: PGP.Failure.badSignature) { try check.verify(Array(SignedVendorFiles.almaLinuxChecksum.utf8)) }
    }
}

private let fedora43Directory = "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Server/aarch64/iso/"
private let fedora43Listing = #"<a href="Fedora-Server-netinst-aarch64-43-1.6.iso">Fedora-Server-netinst-aarch64-43-1.6.iso</a>"#

/// Fedora signs each release's CHECKSUM inline with that release's own key; 43 and 44 are pinned.
struct FedoraReleaseProviderTests {
    @Test func theRealFedora43ChecksumVerifiesAgainstItsPinnedReleaseKey() throws {
        let text = try PGP.Check.verifyClearSigned(
            Array(SignedVendorFiles.fedora43Checksum.utf8), keys: [PGP.PinnedKeys.fedora43.publicKey()], now: pgpGoldenNow)
        let lines = utf8String(text).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(
            lines.contains(
                "SHA256 (Fedora-Server-netinst-aarch64-43-1.6.iso) = c41d16e78058f1e7b8c8984eac8227e29051e3b762b279db680d76cfcd0f011f"))
    }

    @Test func fedora43ResolvesFromItsClearSignedChecksum() async throws {
        let mirror = FixtureMirror([
            fedora43Directory: fedora43Listing,
            fedora43Directory + "Fedora-Server-43-1.6-aarch64-CHECKSUM": SignedVendorFiles.fedora43Checksum,
        ])
        let resolved = try await LinuxProvider.fedoraServerNetinst(release: 43).resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        let url = try #require(URL(string: fedora43Directory + "Fedora-Server-netinst-aarch64-43-1.6.iso"))
        let digest = "c41d16e78058f1e7b8c8984eac8227e29051e3b762b279db680d76cfcd0f011f"
        #expect(resolved.source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
    }

    @Test func theFedora44KeyDoesNotVouchForRelease43() async {
        let mirror = FixtureMirror([
            fedora43Directory: fedora43Listing,
            fedora43Directory + "Fedora-Server-43-1.6-aarch64-CHECKSUM": SignedVendorFiles.fedoraChecksum,
        ])
        await #expect {
            try await LinuxProvider.fedoraServerNetinst(release: 43).resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.signatureRejected(_, let reason) = error else { return false }
            return reason.contains("not pinned for this download")
        }
    }
}
