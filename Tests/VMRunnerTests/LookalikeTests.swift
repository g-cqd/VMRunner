import Foundation
import Testing

@testable import VMRunner

/// U+212A KELVIN SIGN normalizes to `K`, so Swift's `==` calls the two strings equal although their bytes differ.
struct LookalikeTests {
    private let digest = String(repeating: "ab", count: 32)

    @Test func swiftStringEqualityCannotTellTheKelvinSignFromK() {
        // The premise of the other tests: why names are compared by bytes.
        #expect("\u{212A}ali.iso" == "Kali.iso")
        #expect(!"\u{212A}ali.iso".utf8.elementsEqual("Kali.iso".utf8))
    }

    @Test func aChecksumLineForALookalikeNameIsNotTheLineForTheRealName() {
        let gnu = "\(digest)  \u{212A}ali.iso\n"
        let bsd = "SHA256 (\u{212A}ali.iso) = \(digest)\n"

        #expect(LinuxProvider.ChecksumFormat.gnu.sha256(for: "Kali.iso", in: gnu) == nil)
        #expect(LinuxProvider.ChecksumFormat.bsd.sha256(for: "Kali.iso", in: bsd) == nil)
    }

    @Test func theRealNameStillMatchesNextToALookalike() {
        let other = String(repeating: "cd", count: 32)
        let text = "\(other)  \u{212A}ali.iso\n\(digest)  Kali.iso\n"

        #expect(LinuxProvider.ChecksumFormat.gnu.sha256(for: "Kali.iso", in: text) == digest)
    }

    @Test func aFileNameWithALookalikeIsRefused() throws {
        for url in [
            "https://deb.debian.org/%E2%84%AAali.iso",  // Kelvin sign
            "https://deb.debian.org/ali%E2%84%AA.iso",
            "https://deb.debian.org/%EF%BC%A1.iso",  // full-width A
            "https://deb.debian.org/%C3%85.iso",  // A with ring
            "https://deb.debian.org/%E2%84%AB.iso",  // angstrom sign, which normalizes to the line above
        ] {
            let parsed = try #require(URL(string: url))
            #expect(throws: SetupError.self, "\(url)") { try DownloadPolicy.cacheFileName(for: parsed) }
        }
    }

    @Test func aPlainASCIINameIsStillAccepted() throws {
        let url = try #require(URL(string: "https://deb.debian.org/Kali-linux_2026.3.iso"))
        #expect(try DownloadPolicy.cacheFileName(for: url) == "Kali-linux_2026.3.iso")
    }

    @Test func aListingNameWithALookalikeIsNeverTheNewestRelease() {
        let listing = #"<a href="K-1.0.iso">real</a><a href="\#u{212A}-2.0.iso">lookalike</a>"#

        #expect(LinuxProvider.newest(inListing: listing, prefix: "K-", suffix: ".iso")?.path == "K-1.0.iso")
        #expect(LinuxProvider.newest(inListing: #"<a href="\#u{212A}-2.0.iso">x</a>"#, prefix: "K-", suffix: ".iso") == nil)
    }
}
