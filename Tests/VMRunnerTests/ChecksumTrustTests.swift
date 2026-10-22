import Foundation
import Synchronization
import Testing

@testable import VMRunner

/// Serves fixture files as a mirror would, records every request, and honours the size cap like the real fetcher.
final class FixtureMirror: Sendable {
    struct Request: Equatable, Sendable {
        var url: String
        var limit: Int
    }

    private let files: [String: Data]
    private let log = Mutex<[Request]>([])

    init(_ files: [String: String]) { self.files = files.mapValues { Data($0.utf8) } }

    init(binary files: [String: Data]) { self.files = files }

    var requests: [Request] { log.withLock { $0 } }

    var fetch: SmallFetch {
        { [self] url, limit in
            log.withLock { $0.append(Request(url: url.absoluteString, limit: limit)) }
            guard let data = files[url.absoluteString] else { throw SetupError.badResponse(url, 404) }
            guard data.count <= limit else { throw SetupError.responseTooLarge(url) }
            return data
        }
    }
}

private let debianDirectory = "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/"
private let ubuntuDirectory = "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/"
private let fedoraDirectory = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Server/aarch64/iso/"
private let alpineDirectory = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"

private let debianListing = #"<a href="debian-13.7.0-arm64-netinst.iso">debian-13.7.0-arm64-netinst.iso</a>"#
private let fedoraListing = #"<a href="Fedora-Server-netinst-aarch64-44-1.7.iso">Fedora-Server-netinst-aarch64-44-1.7.iso</a>"#

/// Each signed provider with the files its vendor serves.
private func debianMirror(signature: String = SignedVendorFiles.debianSignature, checksums: String = SignedVendorFiles.debianChecksums)
    -> FixtureMirror
{
    FixtureMirror([
        debianDirectory: debianListing, debianDirectory + "SHA256SUMS": checksums, debianDirectory + "SHA256SUMS.sign": signature,
    ])
}

private func ubuntuMirror(signature: String = SignedVendorFiles.ubuntuSignature, checksums: String = SignedVendorFiles.ubuntuChecksums)
    -> FixtureMirror
{
    FixtureMirror([
        ubuntuDirectory: VendorFiles.ubuntuListing, ubuntuDirectory + "SHA256SUMS": checksums,
        ubuntuDirectory + "SHA256SUMS.gpg": signature,
    ])
}

private func fedoraMirror(checksum: String = SignedVendorFiles.fedoraChecksum) -> FixtureMirror {
    FixtureMirror([fedoraDirectory: fedoraListing, fedoraDirectory + "Fedora-Server-44-1.7-aarch64-CHECKSUM": checksum])
}

private func alpineMirror(signature: String? = SignedVendorFiles.alpineSignature) -> FixtureMirror {
    var files = [
        alpineDirectory: VendorFiles.alpineListing,
        alpineDirectory + "alpine-virt-3.24.2-aarch64.iso.sha256": VendorFiles.alpineChecksum,
    ]
    if let signature { files[alpineDirectory + "alpine-virt-3.24.2-aarch64.iso.asc"] = signature }
    return FixtureMirror(files)
}

private func rejection(_ error: any Error) -> (file: String, reason: String)? {
    guard case SetupError.signatureRejected(let file, let reason) = error else { return nil }
    return (file, reason)
}

struct SignedProviderResolveTests {
    @Test func debianNetinstResolvesFromItsSignedChecksums() async throws {
        let mirror = debianMirror()
        let resolved = try await LinuxProvider.debianNetinst.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        let url = try #require(URL(string: debianDirectory + "debian-13.7.0-arm64-netinst.iso"))
        let digest = "6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b"
        #expect(resolved.source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
        #expect(resolved.imageSignature == nil)
        #expect(
            mirror.requests.map(\.url) == [debianDirectory + "SHA256SUMS", debianDirectory + "SHA256SUMS.sign"],
            "the unsigned listing is not fetched: the signed list names the release")
    }

    @Test func ubuntuResolvesFromItsSignedChecksums() async throws {
        let resolved = try await LinuxProvider.ubuntuServer(release: "26.04").resolve(now: pgpGoldenNow, fetch: ubuntuMirror().fetch)
        let url = try #require(URL(string: ubuntuDirectory + "ubuntu-26.04.1-live-server-arm64.iso"))
        let digest = "af78753c94b924c85c4964c670692a853f7c80299a4064e317edad95462e3168"
        #expect(resolved.source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
    }

    @Test func fedoraResolvesFromItsClearSignedChecksum() async throws {
        let mirror = fedoraMirror()
        let resolved = try await LinuxProvider.fedoraServerNetinst(release: 44).resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        let url = try #require(URL(string: fedoraDirectory + "Fedora-Server-netinst-aarch64-44-1.7.iso"))
        let digest = "a93ebd0322cda5a439039710b727ac1899a06e1c11876cfdf7f27c25b8262cc3"
        #expect(resolved.source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
        #expect(mirror.requests.count == 2, "the signature is inside the checksum file, so nothing else is fetched")
    }

    @Test func alpineKeepsItsSHA256AndCarriesTheISOSignatureToTheDownload() async throws {
        let mirror = alpineMirror()
        let resolved = try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        let url = try #require(URL(string: alpineDirectory + "alpine-virt-3.24.2-aarch64.iso"))
        let digest = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"
        #expect(resolved.source == .remote(url, checksum: Checksum(algorithm: .sha256, value: digest)))
        let check = try #require(resolved.imageSignature)
        #expect(check.signature.hash == .sha512)
        #expect(check.key.fingerprint.hexString.uppercased() == PGP.PinnedKeys.alpineCopa.fingerprint)
        #expect(mirror.requests.last == FixtureMirror.Request(url: url.absoluteString + ".asc", limit: PGP.maximumSignatureSize))
    }

    @Test func signaturesAreFetchedWithTheSmallCap() async throws {
        let mirror = debianMirror()
        _ = try await LinuxProvider.debianNetinst.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        #expect(mirror.requests.last?.limit == PGP.maximumSignatureSize)
        #expect(PGP.maximumSignatureSize <= 16 << 10)
    }

    @Test func aProviderWithoutASignatureReadsItsChecksumFileWithoutFetchingOne() async throws {
        let directory = "https://mirror.stream.centos.org/10-stream/BaseOS/aarch64/iso/"
        let name = "CentOS-Stream-10-20260101.0-aarch64-boot.iso"
        let mirror = FixtureMirror([
            directory: #"<a href="\#(name)">\#(name)</a>"#,
            directory + name + ".SHA256SUM": "SHA256 (\(name)) = \(String(repeating: "ab", count: 32))\n",
        ])
        let resolved = try await LinuxProvider.centOSStream(release: 10, flavor: "boot").resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        #expect(resolved.imageSignature == nil)
        #expect(mirror.requests.count == 2)
    }
}

struct SignedProviderFailClosedTests {
    @Test func aMissingSignatureFailsEverySignedProvider() async {
        let cases: [(LinuxProvider, FixtureMirror)] = [
            (
                .debianNetinst,
                FixtureMirror([debianDirectory: debianListing, debianDirectory + "SHA256SUMS": SignedVendorFiles.debianChecksums])
            ),
            (
                .ubuntuServer(release: "26.04"),
                FixtureMirror([
                    ubuntuDirectory: VendorFiles.ubuntuListing, ubuntuDirectory + "SHA256SUMS": SignedVendorFiles.ubuntuChecksums,
                ])
            ),
            (.alpineVirt, alpineMirror(signature: nil)),
        ]
        for (provider, mirror) in cases {
            await #expect("\(provider.host)") {
                try await provider.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
            } throws: { error in
                rejection(error)?.reason.contains("could not be downloaded") == true
            }
        }
    }

    @Test func anUnsignedFedoraChecksumFileIsRefused() async {
        let name = "Fedora-Server-netinst-aarch64-44-1.7.iso"
        let unsigned = "# \(name): 1257783296 bytes\nSHA256 (\(name)) = \(String(repeating: "ab", count: 32))\n"
        await #expect {
            try await LinuxProvider.fedoraServerNetinst(release: 44).resolve(
                now: pgpGoldenNow, fetch: fedoraMirror(checksum: unsigned).fetch)
        } throws: { error in
            rejection(error)?.file == "Fedora-Server-44-1.7-aarch64-CHECKSUM"
        }
    }

    @Test func aTamperedChecksumFileFailsWithItsOwnSignature() async {
        let tampered = SignedVendorFiles.debianChecksums.replacing("6e93fa17", with: "6e93fa18")
        await #expect {
            try await LinuxProvider.debianNetinst.resolve(now: pgpGoldenNow, fetch: debianMirror(checksums: tampered).fetch)
        } throws: { error in
            let found = rejection(error)
            return found?.file == "SHA256SUMS" && found?.reason.contains("does not match the file") == true
        }
    }

    @Test func aTamperedClearSignedDigestFails() async {
        let tampered = SignedVendorFiles.fedoraChecksum.replacing("= a93ebd03", with: "= a93ebd04")
        await #expect {
            try await LinuxProvider.fedoraServerNetinst(release: 44).resolve(
                now: pgpGoldenNow, fetch: fedoraMirror(checksum: tampered).fetch)
        } throws: { error in
            rejection(error)?.reason.contains("does not match the file") == true
        }
    }

    @Test func aLineAppendedAfterTheClearSignedBlockFails() async {
        let forged =
            SignedVendorFiles.fedoraChecksum + "SHA256 (Fedora-Server-netinst-aarch64-44-1.7.iso) = \(String(repeating: "00", count: 32))\n"
        await #expect {
            try await LinuxProvider.fedoraServerNetinst(release: 44).resolve(now: pgpGoldenNow, fetch: fedoraMirror(checksum: forged).fetch)
        } throws: { error in
            rejection(error) != nil
        }
    }

    @Test func aSignatureFromTheWrongKeyNamesTheKeyThatMadeIt() async {
        // Debian's genuine signature, offered for Ubuntu's file: a real signature, but not by Ubuntu's key.
        let mirror = ubuntuMirror(signature: SignedVendorFiles.debianSignature)
        await #expect {
            try await LinuxProvider.ubuntuServer(release: "26.04").resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            let reason = rejection(error)?.reason
            return reason?.contains("DF9B9C49EAA9298432589D76DA87E80D6294BE9B") == true && reason?.contains("not pinned") == true
        }
    }

    @Test(arguments: ["", "not a signature", "-----BEGIN PGP SIGNATURE-----\n\nAAAA\n-----END PGP SIGNATURE-----\n"])
    func aMalformedSignatureFileFails(garbage: String) async {
        await #expect {
            try await LinuxProvider.debianNetinst.resolve(now: pgpGoldenNow, fetch: debianMirror(signature: garbage).fetch)
        } throws: { error in
            rejection(error)?.file == "SHA256SUMS"
        }
    }

    @Test func anOversizedSignatureFileIsRefusedAtTheCap() async {
        let padded = SignedVendorFiles.debianSignature + String(repeating: "\n", count: PGP.maximumSignatureSize)
        await #expect {
            try await LinuxProvider.debianNetinst.resolve(now: pgpGoldenNow, fetch: debianMirror(signature: padded).fetch)
        } throws: { error in
            rejection(error)?.reason.contains("could not be downloaded") == true
        }
    }

    @Test func anExpiredOrNotYetValidClockFails() async {
        let beforeIt = Date(timeIntervalSince1970: 1_788_000_000)
        await #expect {
            try await LinuxProvider.debianNetinst.resolve(now: beforeIt, fetch: debianMirror().fetch)
        } throws: { error in
            rejection(error)?.reason.contains("future") == true
        }
    }

    @Test func aReleaseWithoutAPinnedKeyIsRefusedNotReadUnsigned() async {
        // Fedora 45's directory names a 45 release, but serves the 44 checksum file: genuinely signed, but by a key that is not
        // pinned for release 45.
        let directory = fedoraDirectory.replacing("/44/", with: "/45/")
        let listing = fedoraListing.replacing("44-1.7", with: "45-1.1")
        let mirror = FixtureMirror([
            directory: listing, directory + "Fedora-Server-45-1.1-aarch64-CHECKSUM": SignedVendorFiles.fedoraChecksum,
        ])
        await #expect {
            try await LinuxProvider.fedoraServerNetinst(release: 45).resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            rejection(error)?.reason.contains("no signing key pinned") == true
        }
    }

    @Test func aListingCannotNameAFileTheSignedListDoesNotHave() async throws {
        let listing = #"<a href="debian-13.8.0-arm64-netinst.iso">x</a>"#
        let mirror = FixtureMirror([
            debianDirectory: listing, debianDirectory + "SHA256SUMS": SignedVendorFiles.debianChecksums,
            debianDirectory + "SHA256SUMS.sign": SignedVendorFiles.debianSignature,
        ])

        let resolved = try await LinuxProvider.debianNetinst.resolve(now: pgpGoldenNow, fetch: mirror.fetch)

        // The release comes from the signed list, so the unsigned listing's 13.8.0 is never chosen or downloaded.
        guard case .remote(let url, _) = resolved.source else {
            Issue.record("expected a remote source")
            return
        }
        #expect(url.lastPathComponent == "debian-13.7.0-arm64-netinst.iso")
    }

    @Test func aSignatureFromAHostOutsideThePolicyIsNeverRequested() async {
        let provider = LinuxProvider(
            host: "downloads.example.com", directoryPath: "/debian/", iso: .fixed(path: "debian.iso"),
            checksum: .shared(fileName: "SHA256SUMS"),
            format: .gnu, trust: SignedChecksumTrust(placement: .detached(suffix: "sign"), keys: [PGP.PinnedKeys.debianCD]))
        let mirror = FixtureMirror([
            "https://downloads.example.com/debian/SHA256SUMS": SignedVendorFiles.debianChecksums,
            "https://downloads.example.com/debian/SHA256SUMS.sign": SignedVendorFiles.debianSignature,
        ])
        await #expect {
            try await provider.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.untrustedURL(let url) = error else { return false }
            return url.host() == "downloads.example.com"
        }
        #expect(!mirror.requests.contains { $0.url.hasSuffix(".sign") })
    }
}

struct ProviderTrustRegistrationTests {
    private var everyImage: [LinuxImage] { LinuxCatalog.images + LinuxCatalog.candidates }

    private func isSigned(_ image: LinuxImage) -> Bool { !(image.provider.trust is HTTPSOnlyTrust) }

    @Test func exactlyTheProvidersWithAPinnedKeyAreSigned() {
        let signed = everyImage.filter(isSigned).map(\.id).sorted()
        #expect(signed == ["alpine-virt", "debian-stable-netinst", "fedora-server-44-netinst", "ubuntu-server-26.04"])
        #expect(LinuxCatalog.images.filter(isSigned).map(\.id).sorted() == ["alpine-virt", "ubuntu-server-26.04"])
    }

    @Test func everySignedProviderPinsKeysThatAreValid() throws {
        for image in everyImage where isSigned(image) {
            let keys: [PGP.PinnedKey]
            switch image.provider.trust {
            case let trust as SignedChecksumTrust: keys = trust.keys
            case let trust as SignedImageTrust: keys = trust.keys
            default: keys = []
            }
            #expect(!keys.isEmpty, "\(image.id) is signed without a pinned key")
            for key in keys { _ = try key.publicKey() }
        }
    }

    @Test func eachTrustNoteSaysWhatTheAppDoesAndDoesNotCheck() {
        for image in everyImage {
            let note = image.trustNotes
            if isSigned(image) {
                #expect(note.contains("built into the app"), "\(image.id) is signed, so its note must name the pinned key")
            } else {
                #expect(!note.contains("built into the app"), "\(image.id) has no pinned key, so its note must not claim one")
            }
        }
    }

    @Test func theSignedProvidersTrustTheCorrectKeyForTheirVendor() {
        let expected: [String: String] = [
            "alpine-virt": PGP.PinnedKeys.alpineCopa.fingerprint, "ubuntu-server-26.04": PGP.PinnedKeys.ubuntuCDImage.fingerprint,
            "debian-stable-netinst": PGP.PinnedKeys.debianCD.fingerprint, "fedora-server-44-netinst": PGP.PinnedKeys.fedora44.fingerprint,
        ]
        for image in everyImage where isSigned(image) {
            let keys = (image.provider.trust as? SignedChecksumTrust)?.keys ?? (image.provider.trust as? SignedImageTrust)?.keys ?? []
            #expect(keys.map(\.fingerprint) == expected[image.id].map { [$0] }, "\(image.id)")
        }
    }
}
