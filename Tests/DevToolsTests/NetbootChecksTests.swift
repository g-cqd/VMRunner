import Foundation
import Testing

@testable import DevTools

/// The pure checks a fetched netboot archive passes, against text the vendor's files and the tools really printed.
struct NetbootChecksTests {
    private static let digest = "124087f5df9ac698bb4e942d603eaae96721e451cdc4706c71a5e42ff863b589"
    private static let archive = "alpine-netboot-3.24.2-aarch64.tar.gz"

    // MARK: Listing and choice

    private static let listing = """
        <html><body><pre>
        <a href="../">../</a>
        <a href="alpine-netboot-3.24.0-aarch64.tar.gz">alpine-netboot-3.24.0-aarch64.tar.gz</a>
        <a href="alpine-netboot-3.24.0-aarch64.tar.gz.asc">alpine-netboot-3.24.0-aarch64.tar.gz.asc</a>
        <a href="alpine-netboot-3.24.0-aarch64.tar.gz.sha256">alpine-netboot-3.24.0-aarch64.tar.gz.sha256</a>
        <a href="alpine-netboot-3.24.0_rc2-aarch64.tar.gz">alpine-netboot-3.24.0_rc2-aarch64.tar.gz</a>
        <a href="alpine-netboot-3.24.0_rc2-aarch64.tar.gz.sha256">alpine-netboot-3.24.0_rc2-aarch64.tar.gz.sha256</a>
        <a href="alpine-netboot-3.24.2-aarch64.tar.gz">alpine-netboot-3.24.2-aarch64.tar.gz</a>
        <a href="alpine-netboot-3.24.2-aarch64.tar.gz.asc">alpine-netboot-3.24.2-aarch64.tar.gz.asc</a>
        <a href="alpine-netboot-3.24.2-aarch64.tar.gz.sha256">alpine-netboot-3.24.2-aarch64.tar.gz.sha256</a>
        <a href="alpine-netboot-3.24.10-aarch64.tar.gz">alpine-netboot-3.24.10-aarch64.tar.gz</a>
        <a href="alpine-netboot-3.24.10-aarch64.tar.gz.sha256">alpine-netboot-3.24.10-aarch64.tar.gz.sha256</a>
        <a href="alpine-virt-3.24.2-aarch64.iso">alpine-virt-3.24.2-aarch64.iso</a>
        </pre></body></html>
        """

    @Test
    func theListingYieldsTheNetbootReleasesAndNeverACandidateOrAnotherImage() {
        let releases = AlpineNetboot.releases(inListing: Self.listing).sorted { $0.version < $1.version }
        #expect(releases.map(\.version) == ["3.24.0", "3.24.10", "3.24.2"])
        #expect(releases.map(\.hasSignature) == [true, false, true])
        #expect(releases.allSatisfy { $0.hasChecksum })
    }

    @Test
    func theNewestReleaseWithASignatureIsChosenAndTheNewerUnsignedOneIsNamed() throws {
        let choice = try AlpineNetboot.choose(from: AlpineNetboot.releases(inListing: Self.listing))
        #expect(choice.release.version == "3.24.2", "3.24.10 is newer than 3.24.2 by number, not by text")
        #expect(choice.passedOver == ["3.24.10"])
        #expect(choice.release.archive == Self.archive)
        #expect(choice.release.signatureFile == Self.archive + ".asc")
    }

    @Test
    func whenTheNewestIsSignedNothingIsPassedOver() throws {
        let signed = Self.listing.replacing(
            "<a href=\"alpine-netboot-3.24.10-aarch64.tar.gz.sha256\">",
            with: "<a href=\"alpine-netboot-3.24.10-aarch64.tar.gz.asc\"></a><a href=\"alpine-netboot-3.24.10-aarch64.tar.gz.sha256\">")
        let choice = try AlpineNetboot.choose(from: AlpineNetboot.releases(inListing: signed))
        #expect(choice.release.version == "3.24.10")
        #expect(choice.passedOver.isEmpty)
    }

    @Test
    func noSignedReleaseIsRefusedNotGuessedAt() {
        let unsigned = Self.listing.split(separator: "\n").filter { !$0.contains(".asc") }.joined(separator: "\n")
        #expect(throws: ToolError.self) { try AlpineNetboot.choose(from: AlpineNetboot.releases(inListing: unsigned)) }
        #expect(throws: ToolError.self) { try AlpineNetboot.choose(from: []) }
    }

    @Test
    func aVersionIsThreeNumbersAndNothingElse() {
        for good in ["3.24.2", "3.9.0", "10.0.12"] { #expect(AlpineNetboot.isVersion(good), "\(good)") }
        for bad in ["3.24", "3.24.2.1", "3.24.0_rc1", "3.24.x", "", "..", "3..2", "latest", "3.24.2-r1", "99999.1.1"] {
            #expect(!AlpineNetboot.isVersion(bad), "\(bad)")
        }
    }

    // MARK: Checksum file

    @Test
    func aChecksumFileForExactlyTheArchiveGivesItsDigest() throws {
        #expect(try NetbootChecks.digest(inChecksumFile: "\(Self.digest)  \(Self.archive)\n", for: Self.archive) == Self.digest)
        #expect(try NetbootChecks.digest(inChecksumFile: "\(Self.digest.uppercased()) *\(Self.archive)", for: Self.archive) == Self.digest)
    }

    @Test
    func aChecksumFileThatIsNotOneLineForTheArchiveIsRefused() {
        let bad = [
            "", "\n", "\(Self.digest)\n", "\(Self.digest)  other.tar.gz\n",
            "\(Self.digest)  \(Self.archive)\n\(Self.digest)  \(Self.archive)\n",
            "xyz  \(Self.archive)\n", "\(Self.digest.dropLast())  \(Self.archive)\n", "\(Self.digest)  \(Self.archive).evil\n",
            "\(String(repeating: "g", count: 64))  \(Self.archive)\n",
        ]
        for text in bad {
            #expect(throws: ToolError.self, "\(text.debugDescription)") {
                try NetbootChecks.digest(inChecksumFile: text, for: Self.archive)
            }
        }
    }

    // MARK: Signature

    private static let keyListing = """
        pub:-:4096:1:293ACD0907D9495A:1418203196:::-:::scESC::::::23::0:
        fpr:::::::::0482D84022F52DF1C4E7CD43293ACD0907D9495A:
        uid:-::::1418203196::0FB74FF08B7C679D11ACB2A97C5F6D4C8FDB37A4::Natanael Copa <ncopa@alpinelinux.org>::::::::::0:
        sub:-:4096:1:9E2CE29C63FE7A06:1418203196::::::e::::::23:
        fpr:::::::::498A2E7C598FFE67966416B19E2CE29C63FE7A06:
        """

    @Test
    func theFingerprintOfAKeyIsTheOneOfItsPrimaryKeyNotOfASubkey() {
        #expect(NetbootChecks.primaryFingerprints(inColonListing: Self.keyListing) == [AlpineNetboot.keyFingerprint])
        #expect(NetbootChecks.primaryFingerprints(inColonListing: "").isEmpty)
        let two =
            Self.keyListing + "\npub:-:4096:1:AAAAAAAAAAAAAAAA:1:::-:::scESC::::::23::0:\nfpr:::::::::" + String(repeating: "a", count: 40)
            + ":\n"
        #expect(
            NetbootChecks.primaryFingerprints(inColonListing: two).count == 2,
            "a second key is seen, so the caller can refuse a file with two")
    }

    private static let goodStatus = """
        [GNUPG:] NEWSIG
        [GNUPG:] KEY_CONSIDERED 0482D84022F52DF1C4E7CD43293ACD0907D9495A 0
        [GNUPG:] SIG_ID RaaLIVN3z2xKSt1CWRyX2HrHzJg 2026-09-17 1789675985
        [GNUPG:] GOODSIG 293ACD0907D9495A Natanael Copa <ncopa@alpinelinux.org>
        [GNUPG:] VALIDSIG 0482D84022F52DF1C4E7CD43293ACD0907D9495A 2026-09-17 1789675985 0 4 0 1 10 00 \(AlpineNetboot.keyFingerprint)
        [GNUPG:] TRUST_UNDEFINED 0 pgp
        """

    @Test
    func aGoodSignatureByThePinnedKeyIsAccepted() {
        #expect(NetbootChecks.isGoodSignature(fromStatus: Self.goodStatus, by: AlpineNetboot.keyFingerprint))
        #expect(NetbootChecks.isGoodSignature(fromStatus: Self.goodStatus, by: AlpineNetboot.keyFingerprint.lowercased()))
    }

    @Test
    func anythingShortOfAGoodSignatureByThePinnedKeyIsRefused() {
        let other = String(repeating: "A", count: 40)
        #expect(!NetbootChecks.isGoodSignature(fromStatus: Self.goodStatus, by: other), "another key")
        #expect(!NetbootChecks.isGoodSignature(fromStatus: "", by: AlpineNetboot.keyFingerprint))
        let withoutValid = Self.goodStatus.split(separator: "\n").filter { !$0.contains("VALIDSIG") }.joined(separator: "\n")
        #expect(!NetbootChecks.isGoodSignature(fromStatus: withoutValid, by: AlpineNetboot.keyFingerprint))
        let withoutGood = Self.goodStatus.split(separator: "\n").filter { !$0.contains("GOODSIG") }.joined(separator: "\n")
        #expect(!NetbootChecks.isGoodSignature(fromStatus: withoutGood, by: AlpineNetboot.keyFingerprint))
        for bad in ["BADSIG", "EXPSIG", "EXPKEYSIG", "REVKEYSIG", "ERRSIG", "NO_PUBKEY", "KEYEXPIRED", "KEYREVOKED"] {
            let tainted = Self.goodStatus + "\n[GNUPG:] \(bad) 293ACD0907D9495A"
            #expect(!NetbootChecks.isGoodSignature(fromStatus: tainted, by: AlpineNetboot.keyFingerprint), "\(bad)")
        }
        // A signing subkey's fingerprint in the first field is not the primary key: only the last field counts.
        let subkey = Self.goodStatus.replacing(
            "0482D84022F52DF1C4E7CD43293ACD0907D9495A 2026-09-17", with: "498A2E7C598FFE67966416B19E2CE29C63FE7A06 2026-09-17"
        ).replacing("00 0482D84022F52DF1C4E7CD43293ACD0907D9495A", with: "00 \(other)")
        #expect(!NetbootChecks.isGoodSignature(fromStatus: subkey, by: AlpineNetboot.keyFingerprint))
    }

    // MARK: Archive listing

    private func line(_ type: String, _ name: String) -> String {
        "\(type)rw-r--r--  0 buildozer buildozer 4525757 Sep 17 19:33 \(name)"
    }

    @Test
    func aListingOfPlainFilesAndDirectoriesInsideTheTargetHasNoProblem() {
        let text = [line("d", "boot/"), line("-", "boot/vmlinuz-virt"), line("-", "boot/dtbs-virt/qcom/a b.dtb")].joined(separator: "\n")
        #expect(NetbootChecks.problems(inTarListing: text).isEmpty)
    }

    @Test
    func linksDevicesAndEntriesThatLeaveTheTargetAreProblems() {
        let cases: [(String, String)] = [
            (line("l", "boot/link -> /etc/passwd"), "symbolic link"), (line("h", "boot/hard link to boot/x"), "hard link"),
            (line("c", "dev/null"), "device"), (line("b", "dev/disk"), "device"), (line("p", "boot/fifo"), "named pipe"),
            (line("-", "/etc/passwd"), "leaves"), (line("-", "../outside"), "leaves"), (line("-", "boot/../../outside"), "leaves"),
            (line("-", "boot/a\u{1B}b"), "control character"), ("garbage", "unreadable"),
        ]
        for (text, expected) in cases {
            let problems = NetbootChecks.problems(inTarListing: text)
            #expect(problems.contains { $0.contains(expected) }, "\(text.debugDescription): \(problems)")
        }
    }
}
