import Foundation
import Testing

@testable import VMRunner

struct PGPBase64Tests {
    @Test(arguments: [("", ""), ("TQ==", "M"), ("TWE=", "Ma"), ("TWFu", "Man"), ("TWFuTQ==", "ManM")])
    func decodesCanonicalText(encoded: String, plain: String) {
        #expect(PGP.Base64.decode(Array(encoded.utf8)) == Array(plain.utf8))
    }

    @Test(arguments: [
        "TWE",  // length not a multiple of four
        "TQ=",  // padding short
        "T===",  // three padding characters
        "=WFu",  // padding first
        "TW=u",  // padding in the middle
        "TWF*",  // outside the alphabet
        "TWF u",  // blank inside
        "TWF-",  // URL-safe alphabet
        "TR==",  // leftover bits that are not zero
        "TWF=",  // leftover bits that are not zero
    ])
    func refusesAnythingElse(encoded: String) {
        #expect(PGP.Base64.decode(Array(encoded.utf8)) == nil)
    }

    @Test func crc24MatchesTheStandardCheckValue() {
        #expect(PGP.Armor.crc24(Array("123456789".utf8)) == 0x21_CF02)
    }
}

struct PGPArmorTests {
    private let debian = Array(SignedVendorFiles.debianSignature.utf8)

    @Test func decodesARealDetachedSignatureAndChecksItsCRC() throws {
        let packets = try PGP.Armor.decodeSignature(debian)
        #expect(packets.first == 0x89, "an old-format signature packet")
        #expect(packets.count == 3 + (Int(packets[1]) << 8 | Int(packets[2])), "the length in the header covers the packet")
    }

    @Test func aDamagedChecksumLineIsRefused() {
        let damaged = SignedVendorFiles.debianSignature.replacing("=clAV", with: "=clAW")
        #expect(throws: PGP.Failure.armorChecksum) { try PGP.Armor.decodeSignature(Array(damaged.utf8)) }
    }

    @Test func aBlockWithoutAChecksumLineIsStillRead() throws {
        let packets = [UInt8](repeating: 0x42, count: 70)
        let armored = TestSigner.armor(packets, checksum: false)
        #expect(try PGP.Armor.decodeSignature(armored) == packets)
    }

    @Test func windowsLineEndingsReadTheSame() throws {
        let crlf = SignedVendorFiles.debianSignature.replacing("\n", with: "\r\n")
        #expect(try PGP.Armor.decodeSignature(Array(crlf.utf8)) == PGP.Armor.decodeSignature(debian))
    }

    @Test func armorHeadersAreSkipped() throws {
        let withHeader = SignedVendorFiles.debianSignature.replacing(
            "-----BEGIN PGP SIGNATURE-----\n", with: "-----BEGIN PGP SIGNATURE-----\nVersion: test\n")
        #expect(try PGP.Armor.decodeSignature(Array(withHeader.utf8)) == PGP.Armor.decodeSignature(debian))
    }

    @Test func refusesTextBeforeTheBlockAStrayCarriageReturnAndAHeaderWithoutAColon() {
        let text = SignedVendorFiles.debianSignature
        let begin = "-----BEGIN PGP SIGNATURE-----\n"
        #expect(throws: PGP.Failure.self) { try PGP.Armor.decodeSignature(Array(("junk\n" + text).utf8)) }
        #expect(throws: PGP.Failure.self) { try PGP.Armor.decodeSignature(Array(text.replacing("iQIz", with: "iQ\rIz").utf8)) }
        #expect(throws: PGP.Failure.self) { try PGP.Armor.decodeSignature(Array(text.replacing(begin, with: begin + "Version\n").utf8)) }
    }

    @Test func refusesTextAfterTheBlockAndASecondBlock() {
        let text = SignedVendorFiles.debianSignature
        #expect(throws: PGP.Failure.self) { try PGP.Armor.decodeSignature(Array((text + "junk\n").utf8)) }
        #expect(throws: PGP.Failure.self) { try PGP.Armor.decodeSignature(Array((text + text).utf8)) }
    }

    @Test func refusesABlockWithoutItsEndLineOrWithBadBase64() {
        let text = SignedVendorFiles.debianSignature
        #expect(throws: PGP.Failure.self) {
            try PGP.Armor.decodeSignature(Array(text.replacing("-----END PGP SIGNATURE-----\n", with: "").utf8))
        }
        #expect(throws: PGP.Failure.self) {
            try PGP.Armor.decodeSignature(Array(text.replacing("iQIzBAABCAAd", with: "iQIzBAAB CAAd").utf8))
        }
        #expect(throws: PGP.Failure.self) { try PGP.Armor.decodeSignature(Array(text.replacing("=clAV\n", with: "=clAV\nTWFu\n").utf8)) }
    }

    @Test(arguments: [
        "", "\n\n", "-----BEGIN PGP SIGNATURE-----\n-----END PGP SIGNATURE-----\n",
        "-----BEGIN PGP MESSAGE-----\n\nTWFu\n-----END PGP MESSAGE-----\n",
    ])
    func refusesEmptyAndOtherInputs(text: String) {
        #expect(throws: PGP.Failure.self) { try PGP.Armor.decodeSignature(Array(text.utf8)) }
    }
}

struct PGPClearSignedTests {
    private let fedora = Array(SignedVendorFiles.fedoraChecksum.utf8)

    @Test func splitsARealMessageIntoItsTextAndSignature() throws {
        let message = try PGP.Armor.decodeClearSigned(fedora)
        #expect(message.hashNames == ["SHA256"])
        let text = utf8String(message.text)
        #expect(
            text.hasPrefix("# Fedora-Server-dvd-aarch64-44-1.7.iso: 3662544896 bytes\nSHA256 (Fedora-Server-dvd-aarch64-44-1.7.iso) = "))
        #expect(
            text.hasSuffix("a93ebd0322cda5a439039710b727ac1899a06e1c11876cfdf7f27c25b8262cc3"),
            "the line break before the signature is not signed")
        #expect(message.canonicalText == Array(text.replacing("\n", with: "\r\n").utf8))
        #expect(message.signature.first == 0x89)
    }

    @Test func dashEscapesAreUndoneAndTrailingBlanksCut() throws {
        let signer = try TestSigner()
        let document = try signer.clearSigned(["-----BEGIN FAKE-----", "a  \t", "- dash", "last "])
        let message = try PGP.Armor.decodeClearSigned(document)
        #expect(utf8String(message.text) == "-----BEGIN FAKE-----\na\n- dash\nlast")
        #expect(utf8String(message.canonicalText) == "-----BEGIN FAKE-----\r\na\r\n- dash\r\nlast")
    }

    @Test func aWindowsCopyOfTheMessageReadsTheSame() throws {
        let crlf = SignedVendorFiles.fedoraChecksum.replacing("\n", with: "\r\n")
        #expect(try PGP.Armor.decodeClearSigned(Array(crlf.utf8)) == PGP.Armor.decodeClearSigned(fedora))
    }

    @Test func aTrailingBlankLineBelongsToTheText() throws {
        let signer = try TestSigner()
        let message = try PGP.Armor.decodeClearSigned(signer.clearSigned(["a", ""]))
        #expect(utf8String(message.canonicalText) == "a\r\n")
    }

    /// A message damaged in one place and the failure that place must produce, branch by branch.
    struct Damage: Sendable {
        var name: String
        var apply: @Sendable (String) -> String
        var expected: PGP.Failure
    }

    private static let damages: [Damage] = [
        Damage(
            name: "a line starting with a dash that is not escaped",
            apply: { $0.replacing("# Fedora-Server-dvd-aarch64-44-1.7.iso:", with: "-x dvd:") },
            expected: .malformedArmor("an unescaped line starting with a dash")),
        Damage(
            name: "no Hash header", apply: { $0.replacing("Hash: SHA256\n", with: "") }, expected: .malformedArmor("no Hash header")),
        Damage(
            name: "an unknown header", apply: { $0.replacing("Hash: SHA256\n", with: "Comment: x\n") },
            expected: .malformedArmor("unknown header in the message")),
        Damage(
            name: "text after the signature",
            apply: { $0.replacing("-----END PGP SIGNATURE-----\n", with: "-----END PGP SIGNATURE-----\nforged\n") },
            expected: .malformedArmor("text after the signature")),
        Damage(
            name: "no signature block at all",
            apply: { text in String(text[..<(text.range(of: "-----BEGIN PGP SIGNATURE-----")?.lowerBound ?? text.endIndex)]) },
            expected: .malformedArmor("no signature block")),
        Damage(
            // The misspelt line is not a boundary, so it is read as text, and the dash-escape guard is the one that refuses it.
            name: "a misspelt signature boundary",
            apply: { $0.replacing("-----BEGIN PGP SIGNATURE-----", with: "-----BEGIN PGP SIGNATUR-----") },
            expected: .malformedArmor("an unescaped line starting with a dash")),
        Damage(
            name: "no end line", apply: { $0.replacing("-----END PGP SIGNATURE-----\n", with: "") },
            expected: .malformedArmor("the block has no end line")),
        Damage(
            name: "no cleartext header", apply: { $0.replacing("-----BEGIN PGP SIGNED MESSAGE-----", with: "") },
            expected: .malformedArmor("no cleartext signature header")),
    ]

    @Test(arguments: damages)
    func refusesAMalformedMessage(damage: Damage) {
        let damaged = damage.apply(SignedVendorFiles.fedoraChecksum)
        #expect(throws: damage.expected, "\(damage.name)") { try PGP.Armor.decodeClearSigned(Array(damaged.utf8)) }
    }

    @Test func refusesATextLineThatLooksLikeAnotherMessageHeader() {
        let injected = SignedVendorFiles.fedoraChecksum.replacing(
            "# Fedora-Server-dvd", with: "-----BEGIN PGP SIGNED MESSAGE-----\n# Fedora-Server-dvd")
        // The injected header line starts with a dash that is not escaped, which is what refuses it.
        #expect(throws: PGP.Failure.malformedArmor("an unescaped line starting with a dash")) {
            try PGP.Armor.decodeClearSigned(Array(injected.utf8))
        }
    }
}
