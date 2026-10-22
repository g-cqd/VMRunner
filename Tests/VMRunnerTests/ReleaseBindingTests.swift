import Foundation
import Testing

@testable import VMRunner

private let ubuntuDirectory = "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/"
private let debianDirectory = "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/"
private let alpineDirectory = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"
private let fedoraDirectory = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Server/aarch64/iso/"

private func link(_ name: String) -> String { #"<a href="\#(name)">\#(name)</a>"# }

private func digest(_ seed: String) -> String { String(repeating: seed, count: 32) }

/// A signature (or a signed message) is a genuine one of the vendor but not necessarily for the release the user means: these
/// tests serve genuine, throwaway-key-signed files for the wrong or an older release and check what the app accepts.
struct ReleaseBindingTests {
    private let signer: TestSigner

    init() throws { signer = try SharedSigner.get() }

    private func armored(_ text: String) throws -> String { utf8String(try signer.detachedSignature(over: Array(text.utf8))) }

    private func signing(_ provider: LinuxProvider, with trust: any ChecksumTrust) -> LinuxProvider {
        var copy = provider
        copy.trust = trust
        return copy
    }

    private func detached(_ suffix: String) -> SignedChecksumTrust {
        SignedChecksumTrust(placement: .detached(suffix: suffix), keys: [signer.pinned])
    }

    // MARK: The bundled floors

    @Test func theOldestAcceptedReleasesAreTheOnesObservedWhenTheKeysWerePinned() {
        #expect(LinuxProvider.ubuntuServer(release: "26.04").minimumVersion == "26.04.1")
        #expect(LinuxProvider.ubuntuServer(release: "26.04").series == "26.04")
        #expect(LinuxProvider.alpineVirt.minimumVersion == "3.24.2")
        #expect(LinuxProvider.debianNetinst.minimumVersion == "13.7.0")
        #expect(LinuxProvider.fedoraServerNetinst(release: 44).minimumVersion == "44-1.7")
        #expect(LinuxProvider.fedoraServerNetinst(release: 44).series == "44")
        #expect(LinuxProvider.almaLinux(release: 10, flavor: "boot").minimumVersion == "10.2")
        #expect(LinuxProvider.almaLinux(release: 10, flavor: "boot").series == "10")
        #expect(LinuxProvider.rocky(release: 10, flavor: "boot").minimumVersion == "10.2")
        #expect(LinuxProvider.rocky(release: 10, flavor: "boot").series == "10")
        #expect(LinuxProvider.fedoraServerNetinst(release: 43).minimumVersion == "43-1.6")
    }

    @Test func everyFloorAndSeriesIsANumberTheComparisonCanRead() {
        for image in LinuxCatalog.images + LinuxCatalog.candidates {
            let provider = image.provider
            if let floor = provider.minimumVersion { #expect(ReleaseVersion(floor) != nil, "\(image.id) floor \(floor)") }
            if let series = provider.series { #expect(ReleaseVersion(series) != nil, "\(image.id) series \(series)") }
        }
    }

    @Test func everyOfferedSignedProviderHasAFloor() {
        for image in LinuxCatalog.images + LinuxCatalog.candidates where !(image.provider.trust is HTTPSOnlyTrust) {
            guard case .newest = image.provider.iso else { continue }
            #expect(image.provider.minimumVersion != nil, "\(image.id) is signed and must not accept an older genuine release")
        }
    }

    // MARK: Series

    @Test func aNewerSeriesOrAnOlderOneIsNotACandidateOfAnotherSeries() {
        let names = [
            "ubuntu-24.04.3-live-server-arm64.iso", "ubuntu-26.04-live-server-arm64.iso", "ubuntu-26.04.1-live-server-arm64.iso",
            "ubuntu-26.10-live-server-arm64.iso", "ubuntu-26.040-live-server-arm64.iso",
        ]
        let inSeries = LinuxProvider.releases(among: names, prefix: "ubuntu-", suffix: "-live-server-arm64.iso", series: "26.04")
        #expect(inSeries.map(\.version) == ["26.04.1", "26.04"])
    }

    @Test func fedoraComposesBelongToTheirRelease() {
        #expect(LinuxProvider.belongs("44-1.7", to: "44"))
        #expect(!LinuxProvider.belongs("440-1.7", to: "44"))
        #expect(!LinuxProvider.belongs("45-1.1", to: "44"))
        #expect(LinuxProvider.belongs("anything", to: nil))
    }

    // MARK: Rollback through the unsigned listing

    @Test func aListingThatHidesTheNewestReleaseCannotDowngradeTheChoice() async throws {
        // Only the GA file is listed; the signed list still names 26.04.1.
        let mirror = FixtureMirror([
            ubuntuDirectory: link("ubuntu-26.04-live-server-arm64.iso"), ubuntuDirectory + "SHA256SUMS": SignedVendorFiles.ubuntuChecksums,
            ubuntuDirectory + "SHA256SUMS.gpg": SignedVendorFiles.ubuntuSignature,
        ])

        let resolved = try await LinuxProvider.ubuntuServer(release: "26.04").resolve(now: pgpGoldenNow, fetch: mirror.fetch)

        guard case .remote(let url, _) = resolved.source else {
            Issue.record("expected a remote source")
            return
        }
        #expect(url.lastPathComponent == "ubuntu-26.04.1-live-server-arm64.iso")
    }

    @Test func aGenuineListFromAnotherUbuntuSeriesIsRefusedAndNamesTheVersion() async throws {
        let list = "\(digest("ab")) *ubuntu-24.04.3-live-server-arm64.iso\n"
        let mirror = FixtureMirror([
            ubuntuDirectory: link("ubuntu-24.04.3-live-server-arm64.iso"), ubuntuDirectory + "SHA256SUMS": list,
            ubuntuDirectory + "SHA256SUMS.gpg": try armored(list),
        ])
        let provider = signing(.ubuntuServer(release: "26.04"), with: detached("gpg"))

        await #expect {
            try await provider.resolve(now: pgpTestNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.missingFile(let what) = error else { return false }
            return what.contains("24.04.3") && what.contains("26.04")
        }
    }

    @Test func aGenuineOlderSignedListIsRefusedEvenWhenTheListingIsHonest() async throws {
        let list = "\(digest("ab")) *ubuntu-24.04.3-live-server-arm64.iso\n"
        let mirror = FixtureMirror([
            ubuntuDirectory: VendorFiles.ubuntuListing, ubuntuDirectory + "SHA256SUMS": list,
            ubuntuDirectory + "SHA256SUMS.gpg": try armored(list),
        ])
        let provider = signing(.ubuntuServer(release: "26.04"), with: detached("gpg"))

        await #expect {
            try await provider.resolve(now: pgpTestNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.missingFile(let what) = error else { return false }
            return what.contains("24.04.3")
        }
    }

    @Test func aSignedPointReleaseBelowTheFloorIsRefused() async throws {
        let list = "\(digest("ab")) *ubuntu-26.04-live-server-arm64.iso\n"
        let mirror = FixtureMirror([
            ubuntuDirectory: link("ubuntu-26.04-live-server-arm64.iso"), ubuntuDirectory + "SHA256SUMS": list,
            ubuntuDirectory + "SHA256SUMS.gpg": try armored(list),
        ])
        let provider = signing(.ubuntuServer(release: "26.04"), with: detached("gpg"))

        await #expect {
            try await provider.resolve(now: pgpTestNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.releaseTooOld(let file, let oldest) = error else { return false }
            return file == "ubuntu-26.04-live-server-arm64.iso" && oldest == "26.04.1"
        }
    }

    @Test func aReplayedOlderDebianListIsRefused() async throws {
        let list = "\(digest("cd"))  debian-13.6.0-arm64-netinst.iso\n"
        let mirror = FixtureMirror([
            debianDirectory: link("debian-13.6.0-arm64-netinst.iso"), debianDirectory + "SHA256SUMS": list,
            debianDirectory + "SHA256SUMS.sign": try armored(list),
        ])
        let provider = signing(.debianNetinst, with: detached("sign"))

        await #expect {
            try await provider.resolve(now: pgpTestNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.releaseTooOld(let file, let oldest) = error else { return false }
            return file == "debian-13.6.0-arm64-netinst.iso" && oldest == "13.7.0"
        }
    }

    @Test func aGenuineOlderAlpineIsRefusedWhenTheNewerOnesAreHidden() async throws {
        // 3.24.0 has a genuine signature, but 3.24.2 is the oldest this app accepts.
        let name = "alpine-virt-3.24.0-aarch64.iso"
        let mirror = FixtureMirror(binary: [
            alpineDirectory: Data(link(name).utf8),
            alpineDirectory + name + ".sha256": Data("\(digest("ef"))  \(name)\n".utf8),
            alpineDirectory + name + ".asc": Data(try signer.detachedSignature(over: Array("the installer".utf8))),
        ])
        let provider = signing(.alpineVirt, with: SignedImageTrust(suffix: "asc", keys: [signer.pinned]))

        await #expect {
            try await provider.resolve(now: pgpTestNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.releaseTooOld(let file, let oldest) = error else { return false }
            return file == name && oldest == "3.24.2"
        }
    }

    @Test func aFedoraComposeBelowTheFloorIsRefused() async throws {
        let name = "Fedora-Server-netinst-aarch64-44-1.2.iso"
        let lines = ["# \(name): 1 bytes", "SHA256 (\(name)) = \(digest("12"))"]
        let mirror = FixtureMirror(binary: [
            fedoraDirectory: Data(link(name).utf8),
            fedoraDirectory + "Fedora-Server-44-1.2-aarch64-CHECKSUM": Data(try signer.clearSigned(lines)),
        ])
        let provider = signing(
            .fedoraServerNetinst(release: 44), with: SignedChecksumTrust(placement: .cleartext, keys: [signer.pinned]))

        await #expect {
            try await provider.resolve(now: pgpTestNow, fetch: mirror.fetch)
        } throws: { error in
            guard case SetupError.releaseTooOld(let file, let oldest) = error else { return false }
            return file == name && oldest == "44-1.7"
        }
    }

    @Test func aReleaseAtTheFloorIsAccepted() async throws {
        let list = "\(digest("ab")) *ubuntu-26.04.1-live-server-arm64.iso\n"
        let mirror = FixtureMirror([
            ubuntuDirectory: link("ubuntu-26.04.1-live-server-arm64.iso"), ubuntuDirectory + "SHA256SUMS": list,
            ubuntuDirectory + "SHA256SUMS.gpg": try armored(list),
        ])
        let provider = signing(.ubuntuServer(release: "26.04"), with: detached("gpg"))

        let resolved = try await provider.resolve(now: pgpTestNow, fetch: mirror.fetch)

        guard case .remote(let url, let checksum) = resolved.source else {
            Issue.record("expected a remote source")
            return
        }
        #expect(url.lastPathComponent == "ubuntu-26.04.1-live-server-arm64.iso")
        #expect(checksum?.value == digest("ab"))
    }
}
