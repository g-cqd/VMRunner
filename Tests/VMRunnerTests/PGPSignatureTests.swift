import Foundation
import Testing

@testable import VMRunner

struct PGPSignatureTests {
    private let signer: TestSigner
    private let data = Array("data".utf8)

    init() throws { signer = try SharedSigner.get() }

    private func body(_ draft: SignatureDraft = SignatureDraft()) throws -> [UInt8] { try signer.signatureBody(over: data, draft) }

    private func parse(_ draft: SignatureDraft = SignatureDraft(), style: TestSigner.PacketStyle = .old) throws -> PGP.Signature {
        try PGP.Signature.parse(packets: TestSigner.packet(try body(draft), style: style))
    }

    // MARK: Accepted

    @Test func readsEveryFieldOfAValidSignature() throws {
        let signature = try parse()
        #expect(signature.type == 0x00)
        #expect(signature.hash == .sha256)
        #expect(signature.created == 1_750_000_000)
        #expect(signature.expiresAfter == nil)
        #expect(signature.issuerFingerprint == signer.key.fingerprint)
        #expect(signature.hashedHeader.prefix(6) == [4, 0, 1, 8, 0, 29])
        #expect(signature.trailer == signature.hashedHeader + [0x04, 0xFF, 0, 0, 0, UInt8(signature.hashedHeader.count)])
        #expect(signature.value.count == 256)
    }

    @Test(arguments: TestSigner.PacketStyle.allCases)
    func readsEveryPacketLengthForm(style: TestSigner.PacketStyle) throws {
        #expect(try parse(style: style) == parse())
    }

    @Test func readsTheExpiryAndTreatsZeroAsNone() throws {
        #expect(try parse(SignatureDraft(extraHashed: [TestSigner.subpacket(3, TestSigner.be32(3600))])).expiresAfter == 3600)
        #expect(try parse(SignatureDraft(extraHashed: [TestSigner.subpacket(3, TestSigner.be32(0))])).expiresAfter == nil)
    }

    @Test func ignoresAnUnknownSubpacketThatIsNotCritical() throws {
        let signature = try parse(SignatureDraft(extraHashed: [TestSigner.subpacket(100, [1, 2, 3])]))
        #expect(signature.created == 1_750_000_000)
        #expect(signature.issuerFingerprint == signer.key.fingerprint)
    }

    @Test func acceptsASubpacketItUnderstandsMarkedCritical() throws {
        let critical = TestSigner.subpacket(2, TestSigner.be32(1_750_000_000), critical: true)
        #expect(try parse(SignatureDraft(replacingCreation: [critical])).created == 1_750_000_000)
    }

    @Test func readsTheTwoByteSubpacketLengthForm() throws {
        // A 200-byte note (type 20, not critical) uses the two-octet length: (200 + 1 - 192) in the first byte pair.
        let long = [UInt8(192), UInt8(200 + 1 - 192), 20] + [UInt8](repeating: 0, count: 200)
        #expect(try parse(SignatureDraft(extraHashed: [long])).created == 1_750_000_000)
    }

    @Test func doesNotTrustAnythingInTheUnhashedArea() throws {
        // The signature is made by the test key but an unhashed issuer key ID names another key: nothing reads it.
        let other = TestSigner.subpacket(16, [UInt8](repeating: 0x11, count: 8))
        #expect(try parse(SignatureDraft(unhashed: [other])) == parse())
        // An issuer fingerprint only in the unhashed area is no issuer at all.
        let unhashedOnly = TestSigner.subpacket(33, [4] + signer.key.fingerprint)
        #expect(throws: PGP.Failure.self) { try parse(SignatureDraft(issuer: .none, unhashed: [unhashedOnly])) }
    }

    @Test func readsTheRealVendorSignatures() throws {
        let cases: [(String, PGP.PinnedKey)] = [
            (SignedVendorFiles.debianSignature, PGP.PinnedKeys.debianCD),
            (SignedVendorFiles.ubuntuSignature, PGP.PinnedKeys.ubuntuCDImage),
            (SignedVendorFiles.alpineSignature, PGP.PinnedKeys.alpineCopa),
        ]
        for ((armored, key), hash) in zip(cases, [PGP.HashAlgorithm.sha256, .sha512, .sha512]) {
            let signature = try PGP.Signature.parse(packets: PGP.Armor.decodeSignature(Array(armored.utf8)))
            #expect(signature.hash == hash)
            #expect(signature.type == 0x00)
            #expect(signature.issuerFingerprint.hexString.uppercased() == key.fingerprint)
        }
    }

    // MARK: Refused: what the signature says

    @Test(arguments: [UInt8(2), 3, 5, 6])
    func refusesAnySignatureVersionButFour(version: UInt8) {
        #expect(throws: PGP.Failure.unsupportedVersion(version)) { try parse(SignatureDraft(version: version)) }
    }

    @Test(arguments: [UInt8(3), 16, 17, 18, 19, 22, 25, 27])
    func refusesAnyKeyAlgorithmButRSA(algorithm: UInt8) {
        #expect(throws: PGP.Failure.unsupportedPublicKeyAlgorithm(algorithm)) { try parse(SignatureDraft(algorithm: algorithm)) }
    }

    @Test(arguments: [UInt8(0), 1, 2, 3, 4, 5, 11, 12, 14, 255])
    func refusesAnyHashButSHA2(hash: UInt8) {
        // MD5 (1), SHA-1 (2) and RIPEMD-160 (3) are the ones that matter; SHA-224 (11) and the rest go with them.
        #expect(throws: PGP.Failure.unsupportedHashAlgorithm(hash)) { try parse(SignatureDraft(hash: hash)) }
    }

    @Test(arguments: [UInt8(0x02), 0x10, 0x11, 0x12, 0x13, 0x18, 0x1F, 0x20, 0x28, 0x30, 0x40, 0x50, 0xFF])
    func refusesEveryTypeButBinaryAndText(type: UInt8) {
        #expect(throws: PGP.Failure.unsupportedType(type)) { try parse(SignatureDraft(type: type)) }
    }

    @Test func refusesAnUnknownSubpacketMarkedCritical() {
        #expect(throws: PGP.Failure.unknownCriticalSubpacket(100)) {
            try parse(SignatureDraft(extraHashed: [TestSigner.subpacket(100, [1], critical: true)]))
        }
        // A critical notation (type 20) is one the app does not understand either.
        #expect(throws: PGP.Failure.unknownCriticalSubpacket(20)) {
            try parse(SignatureDraft(extraHashed: [TestSigner.subpacket(20, [0, 0, 0, 0, 0, 0, 0, 0], critical: true)]))
        }
    }

    @Test func refusesAMissingOrRepeatedCreationTimeAndIssuer() {
        let creation = TestSigner.subpacket(2, TestSigner.be32(1_750_000_000))
        #expect(throws: PGP.Failure.self, "no creation time") { try parse(SignatureDraft(replacingCreation: [])) }
        #expect(throws: PGP.Failure.self, "two creation times") { try parse(SignatureDraft(replacingCreation: [creation, creation])) }
        #expect(throws: PGP.Failure.self, "no issuer") { try parse(SignatureDraft(issuer: .none)) }
        let fingerprint = TestSigner.subpacket(33, [4] + signer.key.fingerprint)
        #expect(throws: PGP.Failure.self, "two issuers") { try parse(SignatureDraft(extraHashed: [fingerprint])) }
    }

    @Test func refusesAnIssuerThatIsNotAVersion4FingerprintOrDisagreesWithTheKeyID() {
        let version5 = TestSigner.subpacket(33, [5] + signer.key.fingerprint)
        #expect(throws: PGP.Failure.self, "version 5") { try parse(SignatureDraft(issuer: .none, extraHashed: [version5])) }
        let short = TestSigner.subpacket(33, [4] + signer.key.fingerprint.dropLast())
        #expect(throws: PGP.Failure.self, "short") { try parse(SignatureDraft(issuer: .none, extraHashed: [short])) }
        let wrongID = TestSigner.subpacket(16, [UInt8](repeating: 0x11, count: 8))
        #expect(throws: PGP.Failure.self, "key ID") { try parse(SignatureDraft(extraHashed: [wrongID])) }
        let rightID = TestSigner.subpacket(16, Array(signer.key.fingerprint.suffix(8)))
        #expect(throws: Never.self) { _ = try parse(SignatureDraft(extraHashed: [rightID])) }
    }

    @Test func refusesABadSubpacketBody() {
        #expect(throws: PGP.Failure.self, "short creation time") {
            try parse(SignatureDraft(replacingCreation: [TestSigner.subpacket(2, [0, 0, 1])]))
        }
        #expect(throws: PGP.Failure.self, "empty subpacket") { try parse(SignatureDraft(extraHashed: [[0]])) }
        #expect(throws: PGP.Failure.self, "two expiries") {
            let expiry = TestSigner.subpacket(3, TestSigner.be32(5))
            _ = try parse(SignatureDraft(extraHashed: [expiry, expiry]))
        }
    }

    // MARK: Refused: framing

    @Test func refusesEveryTruncation() throws {
        let whole = try body()
        for length in 0..<whole.count {
            // The header's own length matches the cut body, so the cut is inside the packet, not at its edge.
            #expect(throws: PGP.Failure.self, "cut to \(length) bytes") {
                try PGP.Signature.parse(packets: TestSigner.packet(Array(whole.prefix(length))))
            }
        }
        for length in 0..<TestSigner.packet(whole).count {
            #expect(throws: PGP.Failure.self, "packet cut to \(length) bytes") {
                try PGP.Signature.parse(packets: Array(TestSigner.packet(whole).prefix(length)))
            }
        }
    }

    @Test func refusesALengthThatLiesInTheHashedAreaOrTheUnhashedArea() throws {
        let whole = try body()
        for (offset, change) in [(5, 1), (5, -1), (5, 6), (5, -6), (4, 1), (4, 255)] {
            var damaged = whole
            damaged[offset] = UInt8(truncatingIfNeeded: Int(damaged[offset]) + change)
            #expect(throws: PGP.Failure.self, "hashed length byte \(offset) changed by \(change)") {
                try PGP.Signature.parse(packets: TestSigner.packet(damaged))
            }
        }
        let unhashedLength = 6 + 29
        for change in [1, -1, 200] {
            var damaged = whole
            damaged[unhashedLength + 1] = UInt8(truncatingIfNeeded: Int(damaged[unhashedLength + 1]) + change)
            #expect(throws: PGP.Failure.self, "unhashed length changed by \(change)") {
                try PGP.Signature.parse(packets: TestSigner.packet(damaged))
            }
        }
    }

    @Test func refusesBytesAfterTheSignatureValueAndAfterThePacket() throws {
        let whole = try body()
        #expect(throws: PGP.Failure.self, "inside the packet") { try PGP.Signature.parse(packets: TestSigner.packet(whole + [0])) }
        #expect(throws: PGP.Failure.self, "after the packet") { try PGP.Signature.parse(packets: TestSigner.packet(whole) + [0]) }
        #expect(throws: PGP.Failure.self, "a stray header") { try PGP.Signature.parse(packets: TestSigner.packet(whole) + [0x89]) }
    }

    @Test func refusesNoSignatureAndSeveralSignatures() throws {
        let packet = TestSigner.packet(try body())
        #expect(throws: PGP.Failure.self) { try PGP.Signature.parse(packets: []) }
        #expect(throws: PGP.Failure.signatureCount(2)) { try PGP.Signature.parse(packets: packet + packet) }
        #expect(throws: PGP.Failure.signatureCount(3)) { try PGP.Signature.parse(packets: packet + packet + packet) }
    }

    @Test func refusesAPacketThatIsNotASignatureAndLengthsItNeverNeeds() throws {
        let whole = try body()
        #expect(throws: PGP.Failure.self, "a public key packet") {
            try PGP.Signature.parse(packets: [0x99] + TestSigner.be16(whole.count) + whole)
        }
        #expect(throws: PGP.Failure.self, "a one-pass signature packet") {
            try PGP.Signature.parse(packets: [0x90] + [UInt8(whole.count % 256)] + whole)
        }
        #expect(throws: PGP.Failure.self, "a partial length") { try PGP.Signature.parse(packets: [0xC2, 0xE5] + whole) }
        #expect(throws: PGP.Failure.self, "an indefinite length") { try PGP.Signature.parse(packets: [0x8B] + whole) }
        #expect(throws: PGP.Failure.self, "no marker bit") {
            try PGP.Signature.parse(packets: [0x09] + TestSigner.be16(whole.count) + whole)
        }
        #expect(throws: PGP.Failure.self, "a length past the data") { try PGP.Signature.parse(packets: [0x89, 0xFF, 0xFF] + whole) }
    }

    @Test func refusesAMalformedSignatureInteger() throws {
        let whole = try body()
        let value = try parse().value
        let head = Array(whole.dropLast(2 + value.count))
        let bits = value.count * 8 - value[0].leadingZeroBitCount
        let variants: [(String, [UInt8])] = [
            ("zero bits", TestSigner.be16(0)),
            ("a leading zero byte", TestSigner.be16(bits + 8) + [0] + value),
            ("a bit count that is too small", TestSigner.be16(bits - 1) + value),
            ("a bit count that is too large", TestSigner.be16(bits + 1) + value),
            ("a missing byte", TestSigner.be16(bits) + value.dropLast()),
            ("no integer at all", []),
        ]
        for (name, tail) in variants {
            #expect(throws: PGP.Failure.self, "\(name)") { try PGP.Signature.parse(packets: TestSigner.packet(head + tail)) }
        }
        #expect(throws: Never.self) { _ = try PGP.Signature.parse(packets: TestSigner.packet(head + TestSigner.be16(bits) + value)) }
    }
}
