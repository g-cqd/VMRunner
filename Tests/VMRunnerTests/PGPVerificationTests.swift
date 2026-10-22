import CryptoKit
import Foundation
import Security
import Testing

@testable import VMRunner

/// The day the real vendor files were captured; every real signature below is older and none of them expires.
let pgpGoldenNow = Date(timeIntervalSince1970: 1_792_540_800)

struct PGPGoldenTests {
    private func keys(_ pinned: PGP.PinnedKey...) throws -> [PGP.RSAPublicKey] { try pinned.map { try $0.publicKey() } }

    @Test func debianChecksumsVerifyAgainstThePinnedDebianKey() throws {
        let check = try PGP.Check.detached(
            Array(SignedVendorFiles.debianSignature.utf8), keys: keys(PGP.PinnedKeys.debianCD), now: pgpGoldenNow)
        try check.verify(Array(SignedVendorFiles.debianChecksums.utf8))
    }

    @Test func ubuntuChecksumsVerifyAgainstThePinnedUbuntuKey() throws {
        let check = try PGP.Check.detached(
            Array(SignedVendorFiles.ubuntuSignature.utf8), keys: keys(PGP.PinnedKeys.ubuntuCDImage), now: pgpGoldenNow)
        try check.verify(Array(SignedVendorFiles.ubuntuChecksums.utf8))
        #expect(check.signature.hash == .sha512)
    }

    @Test func fedoraChecksumVerifiesAgainstThePinnedReleaseKeyAndYieldsOnlyTheSignedText() throws {
        let text = try PGP.Check.verifyClearSigned(
            Array(SignedVendorFiles.fedoraChecksum.utf8), keys: keys(PGP.PinnedKeys.fedora44), now: pgpGoldenNow)
        let lines = utf8String(text).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(
            lines.contains(
                "SHA256 (Fedora-Server-netinst-aarch64-44-1.7.iso) = a93ebd0322cda5a439039710b727ac1899a06e1c11876cfdf7f27c25b8262cc3"))
    }

    @Test func theAlpineSignatureIsVettedAgainstThePinnedKey() throws {
        // The signature covers an 89 MB installer that is not a fixture, so only its vetting is exercised here: the issuer,
        // hash, type and validity window. Checking it against the real file was done once by hand (see the research note).
        let check = try PGP.Check.detached(
            Array(SignedVendorFiles.alpineSignature.utf8), keys: keys(PGP.PinnedKeys.alpineCopa), now: pgpGoldenNow)
        #expect(check.signature.hash == .sha512)
        #expect(throws: PGP.Failure.badSignature) { try check.verify(Array("not the installer".utf8)) }
    }

    @Test(arguments: [1, 7, 64, 1000])
    func aFileFedThroughInChunksVerifiesLikeOneHeldInMemory(chunk: Int) throws {
        let data = Array(SignedVendorFiles.ubuntuChecksums.utf8)
        let check = try PGP.Check.detached(
            Array(SignedVendorFiles.ubuntuSignature.utf8), keys: keys(PGP.PinnedKeys.ubuntuCDImage), now: pgpGoldenNow)
        var digest = check.makeDigest()
        for start in stride(from: 0, to: data.count, by: chunk) { digest.update(data[start..<min(start + chunk, data.count)]) }
        try check.verify(digest)

        var short = check.makeDigest()
        short.update(data.dropLast())
        #expect(throws: PGP.Failure.badSignature) { try check.verify(short) }
    }

    @Test func aSignatureFromAnotherPinnedKeyIsRefusedWithTheSignersFingerprint() throws {
        let debian = Array(SignedVendorFiles.debianSignature.utf8)
        let others = try keys(PGP.PinnedKeys.ubuntuCDImage, PGP.PinnedKeys.fedora44, PGP.PinnedKeys.alpineCopa)
        #expect(throws: PGP.Failure.unpinnedSigner("DF9B9C49EAA9298432589D76DA87E80D6294BE9B")) {
            try PGP.Check.detached(debian, keys: others, now: pgpGoldenNow)
        }
        #expect(throws: PGP.Failure.unpinnedSigner("DF9B9C49EAA9298432589D76DA87E80D6294BE9B")) {
            try PGP.Check.detached(debian, keys: [], now: pgpGoldenNow)
        }
    }

    @Test func everyFlippedBitOfTheSignedFileIsDetected() throws {
        let data = Array(SignedVendorFiles.debianChecksums.utf8)
        let check = try PGP.Check.detached(
            Array(SignedVendorFiles.debianSignature.utf8), keys: keys(PGP.PinnedKeys.debianCD), now: pgpGoldenNow)
        for index in data.indices {
            for bit in 0..<8 {
                var flipped = data
                flipped[index] ^= 1 << UInt8(bit)
                #expect(throws: PGP.Failure.badSignature, "byte \(index) bit \(bit)") { try check.verify(flipped) }
            }
        }
        #expect(throws: PGP.Failure.badSignature) { try check.verify(data + [0x0A]) }
        #expect(throws: PGP.Failure.badSignature) { try check.verify(Array(data.dropLast())) }
        #expect(throws: PGP.Failure.badSignature) { try check.verify([]) }
    }

    @Test func everyFlippedBitOfTheSignaturePacketEitherFailsOrChangesNothingThatIsSigned() throws {
        let data = Array(SignedVendorFiles.debianChecksums.utf8)
        let packets = try PGP.Armor.decodeSignature(Array(SignedVendorFiles.debianSignature.utf8))
        let original = try PGP.Signature.parse(packets: packets)
        let debian = try keys(PGP.PinnedKeys.debianCD)
        var accepted = 0
        for index in packets.indices {
            for bit in 0..<8 {
                var flipped = packets
                flipped[index] ^= 1 << UInt8(bit)
                guard let check = try? PGP.Check(PGP.Signature.parse(packets: flipped), expecting: 0x00, keys: debian, now: pgpGoldenNow),
                    (try? check.verify(data)) != nil
                else { continue }
                // Only a flip in the unhashed area, which no signature covers, may pass; the parsed signature is then the same.
                accepted += 1
                #expect(check.signature == original, "byte \(index) bit \(bit) changed something that is signed and still verified")
            }
        }
        #expect(accepted <= 80, "only the 10 unhashed bytes can change without effect")
    }

    @Test func aTamperedCleartextMessageIsRefused() throws {
        let fedora = try keys(PGP.PinnedKeys.fedora44)
        let damaged = SignedVendorFiles.fedoraChecksum.replacing("= a93ebd03", with: "= a93ebd04")
        #expect(throws: PGP.Failure.badSignature) { try PGP.Check.verifyClearSigned(Array(damaged.utf8), keys: fedora, now: pgpGoldenNow) }
        let appended = SignedVendorFiles.fedoraChecksum + "SHA256 (Fedora-Server-netinst-aarch64-44-1.7.iso) = 00\n"
        #expect(throws: PGP.Failure.self) { try PGP.Check.verifyClearSigned(Array(appended.utf8), keys: fedora, now: pgpGoldenNow) }
        let extraLine = SignedVendorFiles.fedoraChecksum.replacing(
            "-----BEGIN PGP SIGNATURE-----", with: "forged\n-----BEGIN PGP SIGNATURE-----")
        #expect(throws: PGP.Failure.badSignature) {
            try PGP.Check.verifyClearSigned(Array(extraLine.utf8), keys: fedora, now: pgpGoldenNow)
        }
    }

    @Test func trailingBlanksOnACleartextLineAreNotSigned() throws {
        // By the format's definition, not a weakness: a signer cuts them before signing, so they cannot carry anything.
        let padded = SignedVendorFiles.fedoraChecksum.replacing("bytes\nSHA256", with: "bytes  \t\nSHA256")
        let text = try PGP.Check.verifyClearSigned(Array(padded.utf8), keys: [PGP.PinnedKeys.fedora44.publicKey()], now: pgpGoldenNow)
        #expect(!utf8String(text).contains(" \n"))
    }

    @Test func aWrongHashPrefixFailsEvenBeforeAnyPublicKeyWork() throws {
        let key = try PGP.PinnedKeys.debianCD.publicKey()
        let signature = try PGP.Signature.parse(packets: PGP.Armor.decodeSignature(Array(SignedVendorFiles.debianSignature.utf8)))
        var forged = signature
        forged.hashPrefix = [signature.hashPrefix[0] ^ 0xFF, signature.hashPrefix[1]]
        let check = try PGP.Check(forged, expecting: 0x00, keys: [key], now: pgpGoldenNow)
        #expect(throws: PGP.Failure.badSignature) { try check.verify(Array(SignedVendorFiles.debianChecksums.utf8)) }
    }
}

struct PGPSyntheticSignatureTests {
    private let signer: TestSigner
    private let data = Array("SHA256SUMS of a synthetic release\n".utf8)

    init() throws { signer = try SharedSigner.get() }

    private func verify(_ armored: [UInt8], now: Date = pgpTestNow) throws {
        try PGP.Check.detached(armored, keys: [signer.key], now: now).verify(data)
    }

    @Test(arguments: [UInt8(8), 9, 10], TestSigner.PacketStyle.allCases)
    func verifiesEveryAcceptedHashAndPacketForm(hash: UInt8, style: TestSigner.PacketStyle) throws {
        try verify(signer.detachedSignature(over: data, SignatureDraft(hash: hash), style: style))
    }

    @Test func verifiesAFileThatIsEmpty() throws {
        let armored = try signer.detachedSignature(over: [])
        try PGP.Check.detached(armored, keys: [signer.key], now: pgpTestNow).verify([])
    }

    @Test func verifiesACleartextMessageAndHandsBackExactlyItsText() throws {
        let document = try signer.clearSigned(["alpha", "- beta  ", "-----gamma", "", "delta"])
        let text = try PGP.Check.verifyClearSigned(document, keys: [signer.key], now: pgpTestNow)
        #expect(utf8String(text) == "alpha\n- beta\n-----gamma\n\ndelta")
    }

    @Test func aFlippedBitInTheFileOrTheSignatureFails() throws {
        let armored = try signer.detachedSignature(over: data)
        var flipped = data
        flipped[3] ^= 1
        #expect(throws: PGP.Failure.badSignature) { try PGP.Check.detached(armored, keys: [signer.key], now: pgpTestNow).verify(flipped) }

        var packets = try PGP.Armor.decodeSignature(armored)
        packets[packets.count - 5] ^= 0x10
        #expect(throws: PGP.Failure.badSignature) { try verify(TestSigner.armor(packets)) }
    }

    @Test func aSignatureFromAnotherKeyFailsEvenWhenItClaimsThePinnedIssuer() throws {
        let impostor = try TestSigner()
        let draft = SignatureDraft(issuer: .fingerprint(signer.key.fingerprint))
        let armored = try impostor.detachedSignature(over: data, draft)
        #expect(throws: PGP.Failure.badSignature) { try verify(armored) }
        let honest = try impostor.detachedSignature(over: data)
        #expect(throws: PGP.Failure.unpinnedSigner(impostor.key.fingerprint.hexString.uppercased())) { try verify(honest) }
    }

    @Test func aSignatureThatClaimsTheFutureOrPredatesItsKeyOrHasExpiredFails() throws {
        let now = UInt32(pgpTestNow.timeIntervalSince1970)
        #expect(throws: PGP.Failure.notYetValid) { try verify(signer.detachedSignature(over: data, SignatureDraft(created: now + 1))) }
        try verify(signer.detachedSignature(over: data, SignatureDraft(created: now)))
        #expect(throws: PGP.Failure.predatesKey) {
            try verify(signer.detachedSignature(over: data, SignatureDraft(created: TestSigner.keyCreated - 1)))
        }
        try verify(signer.detachedSignature(over: data, SignatureDraft(created: TestSigner.keyCreated)))

        let lasting = TestSigner.subpacket(3, TestSigner.be32(100))
        #expect(throws: PGP.Failure.expired) {
            try verify(signer.detachedSignature(over: data, SignatureDraft(created: now - 100, extraHashed: [lasting])))
        }
        try verify(signer.detachedSignature(over: data, SignatureDraft(created: now - 99, extraHashed: [lasting])))
        let forever = TestSigner.subpacket(3, TestSigner.be32(0))
        try verify(signer.detachedSignature(over: data, SignatureDraft(created: now - 100_000_000, extraHashed: [forever])))
    }

    @Test func aClockThatCannotBeRepresentedFailsClosed() throws {
        let armored = try signer.detachedSignature(over: data)
        #expect(throws: PGP.Failure.notYetValid) { try verify(armored, now: Date(timeIntervalSince1970: .nan)) }
    }

    @Test func aDetachedSignatureOfTheTextTypeAndACleartextSignatureOfTheBinaryTypeAreRefused() throws {
        let text = try signer.detachedSignature(over: data, SignatureDraft(type: 0x01))
        #expect(throws: PGP.Failure.unsupportedType(0x01)) { try verify(text) }
        let binary = try signer.clearSigned(["a"], type: 0x00)
        #expect(throws: PGP.Failure.unsupportedType(0x00)) { try PGP.Check.verifyClearSigned(binary, keys: [signer.key], now: pgpTestNow) }
    }

    @Test func aHashHeaderThatDoesNotNameTheSignaturesHashIsRefused() throws {
        let document = try signer.clearSigned(["a"], hashHeader: "SHA512")
        #expect(throws: PGP.Failure.self) { try PGP.Check.verifyClearSigned(document, keys: [signer.key], now: pgpTestNow) }
        let several = try signer.clearSigned(["a"], hashHeader: "SHA512, SHA256")
        #expect(throws: Never.self) { _ = try PGP.Check.verifyClearSigned(several, keys: [signer.key], now: pgpTestNow) }
    }

    @Test(arguments: [UInt8(1), 2, 3, 11])
    func aWeakHashIsRefusedBeforeAnyVerification(hash: UInt8) throws {
        let armored = try signer.detachedSignature(over: data, SignatureDraft(hash: hash))
        #expect(throws: PGP.Failure.unsupportedHashAlgorithm(hash)) { try verify(armored) }
    }

    @Test func aSignatureIntegerAtOrAboveTheModulusFails() throws {
        let digest = [UInt8](repeating: 0, count: 32)
        for value in [signer.key.modulus, signer.key.modulus.map { _ in 0xFF }, [1] + signer.key.modulus] {
            #expect(throws: PGP.Failure.badSignature) { try signer.key.verify(digest: digest, hash: .sha256, signature: value) }
        }
    }

    @Test func aSignatureThatIsABytePaddedOnTheLeftStillVerifies() throws {
        // The integer drops its leading zero bytes, so about one signature in 256 is a byte short. Find one and verify it.
        var found = false
        for index in 0..<4000 where !found {
            let message = Array("message \(index)".utf8)
            let armored = try signer.detachedSignature(over: message)
            let value = try PGP.Signature.parse(packets: PGP.Armor.decodeSignature(armored)).value
            guard value.count < signer.key.modulus.count else { continue }
            found = true
            try PGP.Check.detached(armored, keys: [signer.key], now: pgpTestNow).verify(message)
        }
        #expect(found, "no signature with a leading zero byte turned up in 4000 tries")
    }
}

struct PGPDigestVariantTests {
    private let signer: TestSigner

    init() throws { signer = try SharedSigner.get() }

    /// The framework call outside the `#expect` macro, whose expansion would otherwise treat the nil error pointer as unsafe.
    private func verifies(_ key: SecKey, _ algorithm: SecKeyAlgorithm, _ signed: Data, _ signature: Data) -> Bool {
        SecKeyVerifySignature(key, algorithm, signed as CFData, signature as CFData, nil)
    }

    private struct Variant {
        var message: SecKeyAlgorithm
        var digest: SecKeyAlgorithm
        var hash: (Data) -> Data
    }

    private func algorithm(_ index: Int) -> Variant {
        switch index {
        case 0:
            Variant(
                message: .rsaSignatureMessagePKCS1v15SHA256, digest: .rsaSignatureDigestPKCS1v15SHA256,
                hash: { Data(SHA256.hash(data: $0)) })
        case 1:
            Variant(
                message: .rsaSignatureMessagePKCS1v15SHA384, digest: .rsaSignatureDigestPKCS1v15SHA384,
                hash: { Data(SHA384.hash(data: $0)) })
        default:
            Variant(
                message: .rsaSignatureMessagePKCS1v15SHA512, digest: .rsaSignatureDigestPKCS1v15SHA512,
                hash: { Data(SHA512.hash(data: $0)) })
        }
    }

    /// The verifier hands Security.framework a precomputed digest. These tests pin what the digest variant means: it takes the
    /// digest itself (not a message), and it is the same operation as the message variant over the message that made the digest.
    @Test(arguments: 0..<3)
    func theDigestVariantTakesTheDigestAndAgreesWithTheMessageVariant(index: Int) throws {
        let algorithm = algorithm(index)
        let publicKey = try #require(signer.publicSecKey)
        let message = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let digest = algorithm.hash(message)

        let bySigningTheMessage = try #require(SecKeyCreateSignature(signer.privateKey, algorithm.message, message as CFData, nil) as Data?)
        #expect(verifies(publicKey, algorithm.digest, digest, bySigningTheMessage))

        let bySigningTheDigest = try #require(SecKeyCreateSignature(signer.privateKey, algorithm.digest, digest as CFData, nil) as Data?)
        #expect(verifies(publicKey, algorithm.message, message, bySigningTheDigest))
        #expect(bySigningTheDigest == bySigningTheMessage)

        // A digest that is not this message's, the message itself in the digest's place, and a flipped signature all fail.
        var wrongDigest = digest
        wrongDigest[0] ^= 1
        #expect(!verifies(publicKey, algorithm.digest, wrongDigest, bySigningTheMessage))
        #expect(!verifies(publicKey, algorithm.digest, message, bySigningTheMessage))
        var wrongSignature = bySigningTheMessage
        wrongSignature[10] ^= 1
        #expect(!verifies(publicKey, algorithm.digest, digest, wrongSignature))
    }

    @Test func aDigestOfTheWrongSizeForTheAlgorithmIsRefused() throws {
        let publicKey = try #require(signer.publicSecKey)
        let message = Data("m".utf8)
        let signature = try #require(
            SecKeyCreateSignature(signer.privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil) as Data?)
        let sha512 = Data(SHA512.hash(data: message))
        #expect(!verifies(publicKey, .rsaSignatureDigestPKCS1v15SHA256, sha512, signature))
    }
}

struct PGPPinnedKeyTests {
    /// The fingerprints as each vendor publishes them, written out here independently of the constants under test.
    static let published: [(PGP.PinnedKey, String)] = [
        (PGP.PinnedKeys.debianCD, "DF9B9C49EAA9298432589D76DA87E80D6294BE9B"),
        (PGP.PinnedKeys.ubuntuCDImage, "843938DF228D22F7B3742BC0D94AA3F0EFE21092"),
        (PGP.PinnedKeys.fedora44, "36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6"),
        (PGP.PinnedKeys.alpineCopa, "0482D84022F52DF1C4E7CD43293ACD0907D9495A"),
    ]

    // The fingerprint check proves the constants are the key the vendor published, but it is the golden tests (`PGPGoldenTests`)
    // that are the independent check of the pinned moduli: each verifies a signature the vendor really made against the
    // constant, which only the true modulus can do.
    @Test(arguments: published)
    func eachPinnedKeyHashesToTheFingerprintItsVendorPublishes(pinned: PGP.PinnedKey, published: String) throws {
        #expect(pinned.fingerprint == published)
        let modulus = try #require(PGP.bytes(hex: pinned.modulus))
        let exponent = try #require(PGP.bytes(hex: pinned.exponent))
        let recomputed = PGP.RSAPublicKey.fingerprint(modulus: modulus, exponent: exponent, created: pinned.created)
        #expect(recomputed.hexString.uppercased() == published)
        #expect(modulus.count == 512, "RSA-4096")
        #expect(modulus.first.map { $0 & 0x80 != 0 } == true, "exactly 4096 bits")
        #expect(exponent == [0x01, 0x00, 0x01])
        #expect(try pinned.publicKey().fingerprint == recomputed)
    }

    @Test func theTableHoldsEachKeyOnceAndFedoraIsPinnedPerRelease() {
        #expect(Set(PGP.PinnedKeys.all.map(\.fingerprint)).count == PGP.PinnedKeys.all.count)
        #expect(PGP.PinnedKeys.fedora(release: 44) == [PGP.PinnedKeys.fedora44])
        for release in [0, 40, 43, 45, 46, 99] { #expect(PGP.PinnedKeys.fedora(release: release).isEmpty, "Fedora \(release) has no pin") }
    }

    @Test func aDamagedConstantNeverBecomesAKey() throws {
        let good = PGP.PinnedKeys.debianCD
        var flippedDigit = good
        flippedDigit.modulus = String(good.modulus.dropLast()) + (good.modulus.hasSuffix("7") ? "5" : "7")
        var wrongTime = good
        wrongTime.created += 1
        var wrongExponent = good
        wrongExponent.exponent = "010003"
        var oddLength = good
        oddLength.modulus = String(good.modulus.dropLast())
        var notHex = good
        notHex.modulus = "zz" + good.modulus.dropFirst(2)
        var lowercaseFingerprint = good
        lowercaseFingerprint.fingerprint = good.fingerprint.lowercased()
        for (name, damaged) in [
            ("a flipped digit", flippedDigit), ("another creation time", wrongTime), ("another exponent", wrongExponent),
            ("an odd length", oddLength), ("a character outside hexadecimal", notHex), ("a lowercase fingerprint", lowercaseFingerprint),
        ] {
            #expect(throws: PGP.Failure.invalidKey, "\(name)") { try damaged.publicKey() }
        }
    }

    private struct KeyIntegers {
        var modulus: [UInt8]
        var exponent: [UInt8]
    }

    @Test func aKeyWithTheStandardExponentIsAccepted() throws {
        let modulus = try #require(PGP.bytes(hex: PGP.PinnedKeys.debianCD.modulus))
        #expect(try PGP.RSAPublicKey(modulus: modulus, exponent: [1, 0, 1], created: 0).exponent == [1, 0, 1])
    }

    @Test func aKeyOutsideWhatTheVerifierSupportsIsRefused() throws {
        let modulus = try #require(PGP.bytes(hex: PGP.PinnedKeys.debianCD.modulus))
        let last = try #require(modulus.last)
        let exponent = PGP.RSAPublicKey.publicExponent
        let cases: [(String, KeyIntegers)] = [
            ("a 1024-bit modulus", KeyIntegers(modulus: Array(modulus.prefix(128)), exponent: exponent)),
            ("an even modulus", KeyIntegers(modulus: modulus.dropLast() + [last & 0xFE], exponent: exponent)),
            ("a modulus with a leading zero", KeyIntegers(modulus: [0] + modulus.dropFirst(), exponent: exponent)),
            ("an exponent of one", KeyIntegers(modulus: modulus, exponent: [1])),
            ("an even exponent", KeyIntegers(modulus: modulus, exponent: [1, 0, 0])),
            ("no exponent", KeyIntegers(modulus: modulus, exponent: [])),
            ("an exponent of three", KeyIntegers(modulus: modulus, exponent: [3])),
            ("an exponent of seventeen", KeyIntegers(modulus: modulus, exponent: [0x11])),
            ("an exponent of 65539", KeyIntegers(modulus: modulus, exponent: [1, 0, 3])),
            ("an exponent with a leading zero", KeyIntegers(modulus: modulus, exponent: [0, 1, 0, 1])),
            ("an exponent as large as the modulus", KeyIntegers(modulus: modulus, exponent: modulus)),
        ]
        for (name, integers) in cases {
            #expect(throws: PGP.Failure.invalidKey, "\(name)") {
                try PGP.RSAPublicKey(modulus: integers.modulus, exponent: integers.exponent, created: 0)
            }
        }
    }
}

struct PGPKeyExpiryTests {
    private let signer: TestSigner
    private let data = Array("SHA256SUMS of a synthetic release\n".utf8)

    init() throws { signer = try SharedSigner.get() }

    @Test func aPinnedKeyIsRefusedFromTheSecondItExpiresAndAcceptedBefore() throws {
        let now = UInt32(pgpTestNow.timeIntervalSince1970)
        let armored = try signer.detachedSignature(over: data)
        var pinned = signer.pinned
        pinned.expires = now + 1
        try PGP.Check.detached(armored, keys: [pinned.publicKey()], now: pgpTestNow).verify(data)
        pinned.expires = now
        #expect(throws: PGP.Failure.keyExpired) { try PGP.Check.detached(armored, keys: [pinned.publicKey()], now: pgpTestNow) }
    }

    @Test func theExpiryIsNotPartOfTheFingerprint() throws {
        var pinned = signer.pinned
        pinned.expires = 2_000_000_000
        #expect(try pinned.publicKey().fingerprint == signer.key.fingerprint)
    }

    /// Fails 90 days before a pinned key expires, so a release never ships a key that stops working soon after.
    @Test func noPinnedKeyExpiresWithinNinetyDays() {
        let horizon = Date().addingTimeInterval(90 * 86_400)
        for key in PGP.PinnedKeys.all {
            guard let expires = key.expires else { continue }
            #expect(Date(timeIntervalSince1970: TimeInterval(expires)) > horizon, "\(key.owner) expires within 90 days: pin its successor")
        }
    }
}
