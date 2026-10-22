import Foundation
import Synchronization
import TestKit
import Testing

@testable import VMRunner

/// A checksum file of about `bytes` bytes: one line per image, with `entry` on line `entryLine`.
private func syntheticChecksums(bytes: Int, entry: String, digest: String, entryLine: Int) -> String {
    var text = ""
    var line = 0
    while text.utf8.count < bytes {
        line += 1
        let name = line == entryLine ? entry : "image-\(line).iso"
        let hash = line == entryLine ? digest : String(repeating: "0", count: 64)
        text += "\(hash)  \(name)\n"
    }
    return text
}

private let wantedDigest = String(repeating: "ab", count: 32)

/// What a parse of a few megabytes may take. The tests exist to catch a hang or quadratic blow-up (minutes), not to measure speed:
/// a debug build on a busy machine is slow, and a sanitizer build several times slower again.
private var scaleBudget: Duration { sanitizerRuntimeLoaded ? .seconds(150) : .seconds(30) }

struct ChecksumParsingScaleTests {
    @Test func aFourMebibyteChecksumFileIsReadWithinAGenerousBudget() {
        let text = syntheticChecksums(bytes: 4 << 20, entry: "wanted.iso", digest: wantedDigest, entryLine: 3)
        #expect(text.utf8.count >= 4 << 20)

        let clock = ContinuousClock()
        var gnu: String?
        var missing: String?
        let elapsed = clock.measure {
            gnu = LinuxProvider.ChecksumFormat.gnu.sha256(for: "wanted.iso", in: text)
            missing = LinuxProvider.ChecksumFormat.gnu.sha256(for: "absent.iso", in: text)
        }

        #expect(gnu == wantedDigest)
        #expect(missing == nil)
        #expect(elapsed < scaleBudget, "reading a 4 MiB checksum file took \(elapsed)")
    }

    @Test func aBSDFileOfTheSameSizeIsReadWithinTheSameBudget() {
        var text = ""
        for line in 1...60_000 { text += "SHA256 (image-\(line).iso) = \(String(repeating: "0", count: 64))\n" }
        text += "SHA256 (wanted.iso) = \(wantedDigest)\n"

        let clock = ContinuousClock()
        var found: String?
        let elapsed = clock.measure { found = LinuxProvider.ChecksumFormat.bsd.sha256(for: "wanted.iso", in: text) }

        // The entry is past the line cap, which is the point of the cap.
        #expect(found == nil)
        #expect(elapsed < scaleBudget, "reading a BSD checksum file took \(elapsed)")
    }

    @Test func onlyTheFirstLinesAreRead() {
        let cap = LinuxProvider.ChecksumFormat.maximumLines
        let inside = syntheticChecksums(bytes: 1 << 20, entry: "wanted.iso", digest: wantedDigest, entryLine: cap)
        let outside = syntheticChecksums(bytes: 1 << 20, entry: "wanted.iso", digest: wantedDigest, entryLine: cap + 1)

        #expect(LinuxProvider.ChecksumFormat.gnu.sha256(for: "wanted.iso", in: inside) == wantedDigest)
        #expect(LinuxProvider.ChecksumFormat.gnu.sha256(for: "wanted.iso", in: outside) == nil)
    }

    @Test func aHugeLineWithoutANewlineIsSkippedQuickly() {
        let text = String(repeating: "a", count: 4 << 20)
        let clock = ContinuousClock()
        var found: String?
        let elapsed = clock.measure { found = LinuxProvider.ChecksumFormat.gnu.sha256(for: "a", in: text) }

        #expect(found == nil)
        #expect(elapsed < scaleBudget, "a 4 MiB line took \(elapsed)")
    }

    @Test func aLineLongerThanAnyFileNameIsNotRead() {
        let longName = String(repeating: "n", count: LinuxProvider.ChecksumFormat.maximumLineLength)
        let text = "\(wantedDigest)  \(longName)\n\(wantedDigest)  short.iso\n"

        #expect(LinuxProvider.ChecksumFormat.gnu.sha256(for: longName, in: text) == nil)
        #expect(LinuxProvider.ChecksumFormat.gnu.sha256(for: "short.iso", in: text) == wantedDigest)
    }

    @Test func windowsLineEndingsStillSplitLines() {
        let text = "\(String(repeating: "1", count: 64))  other.iso\r\n\(wantedDigest)  wanted.iso\r\n"
        #expect(LinuxProvider.ChecksumFormat.gnu.sha256(for: "wanted.iso", in: text) == wantedDigest)
    }

    @Test func aLargeListingIsSearchedWithinAGenerousBudget() {
        var listing = ""
        for number in 1...20_000 { listing += #"<a href="other-\#(number).txt">other</a>"# + "\n" }
        listing += #"<a href="debian-13.7.0-arm64-netinst.iso">x</a><a href="debian-13.10.0-arm64-netinst.iso">y</a>"#

        let clock = ContinuousClock()
        var newest: LinuxRelease?
        let elapsed = clock.measure {
            newest = LinuxProvider.newest(inListing: listing, prefix: "debian-", suffix: "-arm64-netinst.iso")
        }

        #expect(newest?.version == "13.10.0")
        #expect(elapsed < scaleBudget, "searching a large listing took \(elapsed)")
    }
}

/// Trusts every checksum file and notes whether the work of `resolve` ran on the main thread.
private final class ThreadRecordingTrust: ChecksumTrust {
    let observations = Mutex<[Bool]>([])

    func vouch(for checksumFile: Data, at checksumURL: URL, image imageURL: URL, now: Date, fetch: SmallFetch) async throws
        -> VouchedChecksum
    {
        observations.withLock { $0.append(Self.onMainThread()) }
        return VouchedChecksum(text: try LinuxProvider.text(of: checksumFile, at: checksumURL))
    }

    private static func onMainThread() -> Bool { Thread.isMainThread }
}

@MainActor
struct ResolveIsolationTests {
    @Test func resolvingAProviderDoesNotRunOnTheMainActor() async throws {
        let trust = ThreadRecordingTrust()
        let provider = LinuxProvider(
            host: "deb.debian.org", directoryPath: "/debian/dists/stable/main/installer-arm64/current/images/",
            iso: .fixed(path: "netboot/mini.iso"), checksum: .shared(fileName: "SHA256SUMS"), format: .gnu, trust: trust)
        let checksums = syntheticChecksums(bytes: 4 << 20, entry: "netboot/mini.iso", digest: wantedDigest, entryLine: 5)

        // Called from the main actor, as the provisioner does.
        let resolved = try await provider.resolve { _, _ in Data(checksums.utf8) }

        #expect(trust.observations.withLock { $0 } == [false], "parsing a checksum file must not stall the main actor")
        guard case .remote(_, let checksum) = resolved.source else {
            Issue.record("expected a remote source")
            return
        }
        #expect(checksum?.value == wantedDigest)
    }
}
