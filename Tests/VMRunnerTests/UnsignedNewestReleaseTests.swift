import Foundation
import Testing

@testable import VMRunner

private let alpineDirectory = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"

/// The `alpine-virt` rows of `/alpine/latest-stable/releases/aarch64/` as served on 2026-10-22: 3.24.3 is listed with its
/// checksums but no `.asc` yet, while 3.24.0, 3.24.1 and 3.24.2 have one.
private let capturedListing = """
    <a href="alpine-virt-3.24.0-aarch64.iso">alpine-virt-3.24.0-aarch64.iso</a>                     09-Jun-2026 14:00     88M
    <a href="alpine-virt-3.24.0-aarch64.iso.asc">alpine-virt-3.24.0-aarch64.iso.asc</a>                 09-Jun-2026 14:44     833
    <a href="alpine-virt-3.24.0-aarch64.iso.sha256">alpine-virt-3.24.0-aarch64.iso.sha256</a>              09-Jun-2026 14:00      97
    <a href="alpine-virt-3.24.0_rc1-aarch64.iso">alpine-virt-3.24.0_rc1-aarch64.iso</a>                 08-Jun-2026 08:22     88M
    <a href="alpine-virt-3.24.0_rc2-aarch64.iso">alpine-virt-3.24.0_rc2-aarch64.iso</a>                 08-Jun-2026 20:51     88M
    <a href="alpine-virt-3.24.1-aarch64.iso">alpine-virt-3.24.1-aarch64.iso</a>                     13-Jun-2026 16:41     88M
    <a href="alpine-virt-3.24.1-aarch64.iso.asc">alpine-virt-3.24.1-aarch64.iso.asc</a>                 14-Jun-2026 00:06     833
    <a href="alpine-virt-3.24.1-aarch64.iso.sha256">alpine-virt-3.24.1-aarch64.iso.sha256</a>              13-Jun-2026 16:41      97
    <a href="alpine-virt-3.24.2-aarch64.iso">alpine-virt-3.24.2-aarch64.iso</a>                     17-Sep-2026 17:34     89M
    <a href="alpine-virt-3.24.2-aarch64.iso.asc">alpine-virt-3.24.2-aarch64.iso.asc</a>                 17-Sep-2026 20:13     833
    <a href="alpine-virt-3.24.2-aarch64.iso.sha256">alpine-virt-3.24.2-aarch64.iso.sha256</a>              17-Sep-2026 17:34      97
    <a href="alpine-virt-3.24.3-aarch64.iso">alpine-virt-3.24.3-aarch64.iso</a>                     21-Oct-2026 21:57     89M
    <a href="alpine-virt-3.24.3-aarch64.iso.sha256">alpine-virt-3.24.3-aarch64.iso.sha256</a>              21-Oct-2026 21:57      97
    """

private let sha256For324 = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"
private let sha256For323 = "e34603080e942e9ebc670689eee77dd7a6551c823a6ff5a299e308ded268098f"

private func iso(_ version: String) -> String { "alpine-virt-\(version)-aarch64.iso" }

/// A mirror that serves the captured listing, the checksum files of 3.24.2 and 3.24.3 (as captured) and the genuine signature
/// of 3.24.2. `signed` lists the versions whose `.asc` is served; the signature served for each is the genuine one of 3.24.2,
/// which vets as a signature by the pinned Alpine key.
private func alpine(signed: Set<String>) -> FixtureMirror {
    var files = [
        alpineDirectory: capturedListing,
        alpineDirectory + iso("3.24.1") + ".sha256": "\(String(repeating: "11", count: 32))  \(iso("3.24.1"))\n",
        alpineDirectory + iso("3.24.2") + ".sha256": "\(sha256For324)  \(iso("3.24.2"))\n",
        alpineDirectory + iso("3.24.3") + ".sha256": "\(sha256For323)  \(iso("3.24.3"))\n",
    ]
    for version in signed { files[alpineDirectory + iso(version) + ".asc"] = SignedVendorFiles.alpineSignature }
    return FixtureMirror(files)
}

private func signatureRequests(_ mirror: FixtureMirror) -> [String] {
    mirror.requests.map(\.url).filter { $0.hasSuffix(".asc") }.map { String($0.dropFirst(alpineDirectory.count)) }
}

struct UnsignedNewestReleaseTests {
    @Test func theNewestReleaseWithASignatureIsTakenAndTheOneBeforeItIsReported() async throws {
        let mirror = alpine(signed: ["3.24.2", "3.24.1"])

        let resolved = try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: mirror.fetch)

        let url = try #require(URL(string: alpineDirectory + iso("3.24.2")))
        #expect(resolved.source == .remote(url, checksum: Checksum(algorithm: .sha256, value: sha256For324)))
        #expect(resolved.version == "3.24.2")
        #expect(resolved.unsignedNewer == ["3.24.3"])
        #expect(resolved.notice(named: "Alpine Linux") == "Alpine Linux 3.24.3 has no signature yet; using 3.24.2.")
        let check = try #require(resolved.imageSignature, "the chosen image is still checked against its signature after the download")
        #expect(check.key.fingerprint.hexString.uppercased() == PGP.PinnedKeys.alpineCopa.fingerprint)
        #expect(signatureRequests(mirror) == [iso("3.24.3") + ".asc", iso("3.24.2") + ".asc"])
    }

    @Test func whenTheNewestIsSignedNothingIsReported() async throws {
        let mirror = alpine(signed: ["3.24.3", "3.24.2"])

        let resolved = try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: mirror.fetch)

        #expect(resolved.version == "3.24.3")
        #expect(resolved.unsignedNewer.isEmpty)
        #expect(resolved.notice(named: "Alpine Linux") == nil)
        #expect(signatureRequests(mirror) == [iso("3.24.3") + ".asc"], "no older release is looked at")
    }

    @Test func severalUnsignedReleasesAreAllNamed() {
        var resolved = ResolvedImage(source: .local("x"), imageSignature: nil, version: "3.24.2")
        resolved.unsignedNewer = ["3.24.4", "3.24.3"]
        #expect(resolved.notice(named: "Alpine Linux") == "Alpine Linux 3.24.4 and 3.24.3 have no signature yet; using 3.24.2.")
    }

    @Test func noSignedReleaseAboveTheFloorIsRefusedAndNeverGoesBelowIt() async {
        // 3.24.1 has a genuine signature, but 3.24.2 is the oldest this version of the app accepts.
        let mirror = alpine(signed: ["3.24.1", "3.24.0"])

        await #expect {
            try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.noSignedRelease(let oldest, let unsigned) = error else { return false }
            return oldest == "3.24.2" && unsigned == ["3.24.3", "3.24.2"]
        }
        #expect(signatureRequests(mirror) == [iso("3.24.3") + ".asc", iso("3.24.2") + ".asc"], "3.24.1 is never asked for")
    }

    @Test func aNewestReleaseBelowTheFloorIsStillRefusedAsTooOld() async {
        let listing = capturedListing.split(separator: "\n").filter { !$0.contains("3.24.2") && !$0.contains("3.24.3") }
            .joined(separator: "\n")
        let mirror = FixtureMirror([
            alpineDirectory: listing,
            alpineDirectory + iso("3.24.1") + ".sha256": "\(String(repeating: "11", count: 32))  \(iso("3.24.1"))\n",
            alpineDirectory + iso("3.24.1") + ".asc": SignedVendorFiles.alpineSignature,
        ])

        await #expect {
            try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.releaseTooOld(let file, let oldest) = error else { return false }
            return file == iso("3.24.1") && oldest == "3.24.2"
        }
    }

    // MARK: A failure that is not "not published" must not be answered with an older release

    @Test func aServerErrorOnTheNewestSignatureRefusesWithoutTryingAnOlderRelease() async {
        let mirror = alpine(signed: ["3.24.2"])
        let failing = alpineDirectory + iso("3.24.3") + ".asc"
        let fetch: SmallFetch = { url, limit in
            if url.absoluteString == failing { throw SetupError.badResponse(url, 500) }
            return try await mirror.fetch(url, limit)
        }

        await #expect {
            try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: fetch)
        } throws: { error in
            guard case SetupError.signatureRejected(let file, let reason) = error else { return false }
            return file == iso("3.24.3") && reason.contains("could not be downloaded") && reason.contains("500")
        }
        #expect(signatureRequests(mirror).isEmpty, "3.24.2 is not looked at after a 500 on 3.24.3")
    }

    @Test func aNetworkErrorOnTheNewestSignatureRefusesWithoutTryingAnOlderRelease() async {
        let mirror = alpine(signed: ["3.24.2"])
        let failing = alpineDirectory + iso("3.24.3") + ".asc"
        let fetch: SmallFetch = { url, limit in
            if url.absoluteString == failing { throw URLError(.networkConnectionLost) }
            return try await mirror.fetch(url, limit)
        }

        await #expect {
            try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: fetch)
        } throws: { error in
            guard case SetupError.signatureRejected(let file, _) = error else { return false }
            return file == iso("3.24.3")
        }
        #expect(signatureRequests(mirror).isEmpty)
    }

    @Test(arguments: ["not a signature", "", "-----BEGIN PGP SIGNATURE-----\n\nAAAA\n-----END PGP SIGNATURE-----\n"])
    func aMalformedSignatureOnTheNewestRefusesWithoutTryingAnOlderRelease(garbage: String) async {
        let mirror = alpine(signed: ["3.24.2"])
        let bad = alpineDirectory + iso("3.24.3") + ".asc"
        let fetch: SmallFetch = { url, limit in
            if url.absoluteString == bad { return Data(garbage.utf8) }
            return try await mirror.fetch(url, limit)
        }

        await #expect {
            try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: fetch)
        } throws: { error in
            guard case SetupError.signatureRejected(let file, _) = error else { return false }
            return file == iso("3.24.3")
        }
        #expect(signatureRequests(mirror).isEmpty)
    }

    @Test func aSignatureByAnUnpinnedKeyOnTheNewestRefusesWithoutTryingAnOlderRelease() async {
        let mirror = alpine(signed: ["3.24.2"])
        let other = alpineDirectory + iso("3.24.3") + ".asc"
        let fetch: SmallFetch = { url, limit in
            if url.absoluteString == other { return Data(SignedVendorFiles.debianSignature.utf8) }
            return try await mirror.fetch(url, limit)
        }

        await #expect {
            try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: fetch)
        } throws: { error in
            guard case SetupError.signatureRejected(_, let reason) = error else { return false }
            return reason.contains("not pinned")
        }
        #expect(signatureRequests(mirror).isEmpty)
    }

    @Test func aMissingChecksumFileIsAFailureNotAReasonToTakeAnOlderRelease() async {
        // The listing names 3.24.3, but its checksum file is not served.
        let mirror = FixtureMirror([
            alpineDirectory: capturedListing,
            alpineDirectory + iso("3.24.2") + ".sha256": "\(sha256For324)  \(iso("3.24.2"))\n",
            alpineDirectory + iso("3.24.2") + ".asc": SignedVendorFiles.alpineSignature,
        ])

        await #expect {
            try await LinuxProvider.alpineVirt.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.badResponse(_, 404) = error else { return false }
            return true
        }
    }

    // MARK: The other signed providers keep failing closed

    @Test func providersThatSignAListDoNotWalkBack() {
        #expect(!LinuxProvider.debianNetinst.trust.signsEachImage)
        #expect(!LinuxProvider.ubuntuServer(release: "26.04").trust.signsEachImage)
        #expect(!LinuxProvider.fedoraServerNetinst(release: 44).trust.signsEachImage)
        #expect(LinuxProvider.alpineVirt.trust.signsEachImage)
    }

    @Test func aMissingSignatureOfAListStillFailsClosedWithARejection() async {
        let directory = "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/"
        let mirror = FixtureMirror([directory + "SHA256SUMS": SignedVendorFiles.debianChecksums])

        await #expect {
            try await LinuxProvider.debianNetinst.resolve(now: pgpGoldenNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.signatureRejected = error else { return false }
            return true
        }
    }
}
