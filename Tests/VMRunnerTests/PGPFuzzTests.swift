import Foundation
import Testing

@testable import VMRunner

/// Seeded, deterministic mutation of real vendor files. Two properties are asserted over thousands of mutants:
///
/// 1. Nothing traps, whatever the bytes (a trap would end the test process, so surviving is the assertion).
/// 2. A mutant is accepted only if what it asks the verifier to trust is exactly what the vendor signed: the same file for a
///    mutated signature, and never a different file for a mutated file.
///
/// A failing case reproduces from the seed and index in its message.
struct PGPFuzzTests {
    private static let baseSeed: UInt64 = 0x5047_5046_555A_5A31

    /// A copy of `bytes` with one to three random edits, different from the original.
    private static func mutate(_ bytes: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        var result = bytes
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            guard !result.isEmpty else {
                result.append(UInt8.random(in: 0...255, using: &rng))
                continue
            }
            let position = Int.random(in: 0..<result.count, using: &rng)
            switch Int.random(in: 0..<8, using: &rng) {
            case 0: result[position] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
            case 1: result[position] = UInt8.random(in: 0...255, using: &rng)
            case 2: result.remove(at: position)
            case 3: result.insert(UInt8.random(in: 0...255, using: &rng), at: position)
            case 4: result.removeSubrange(position..<min(result.count, position + Int.random(in: 1...16, using: &rng)))
            case 5: result.removeSubrange(position...)
            case 6:
                result.insert(
                    contentsOf: result[position..<min(result.count, position + Int.random(in: 1...32, using: &rng))], at: position)
            default: result[position] = [0x00, 0xFF, 0x0A, 0x0D, 0x2D, 0x3D, 0x20, 0x09].randomElement(using: &rng) ?? 0
            }
        }
        return result == bytes ? bytes + [UInt8.random(in: 0...255, using: &rng)] : result
    }

    private static func randomBytes(_ rng: inout SplitMix64, count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    private func keys(_ pinned: PGP.PinnedKey) throws -> [PGP.RSAPublicKey] { [try pinned.publicKey()] }

    // MARK: Mutated signature, original file

    @Test(arguments: [0, 1])
    func aMutatedArmoredSignatureIsNeverAcceptedForAnythingButTheSignedFile(vendor: Int) throws {
        let (armored, data, pinned) =
            vendor == 0
            ? (SignedVendorFiles.debianSignature, SignedVendorFiles.debianChecksums, PGP.PinnedKeys.debianCD)
            : (SignedVendorFiles.ubuntuSignature, SignedVendorFiles.ubuntuChecksums, PGP.PinnedKeys.ubuntuCDImage)
        let file = Array(data.utf8)
        let key = try keys(pinned)
        let original = try PGP.Signature.parse(packets: PGP.Armor.decodeSignature(Array(armored.utf8)))
        var accepted = 0
        for index in 0..<3000 {
            var rng = SplitMix64(seed: Self.baseSeed &+ UInt64(vendor) << 32 &+ UInt64(index))
            let mutant = Self.mutate(Array(armored.utf8), &rng)
            guard let check = try? PGP.Check.detached(mutant, keys: key, now: pgpGoldenNow), (try? check.verify(file)) != nil else {
                continue
            }
            accepted += 1
            #expect(check.signature == original, "seed \(vendor) index \(index) was accepted with a different signature")
        }
        #expect(accepted < 3000)
    }

    @Test func aMutatedPacketIsNeverAcceptedForAnythingButTheSignedFile() throws {
        let file = Array(SignedVendorFiles.ubuntuChecksums.utf8)
        let key = try keys(PGP.PinnedKeys.ubuntuCDImage)
        let packets = try PGP.Armor.decodeSignature(Array(SignedVendorFiles.ubuntuSignature.utf8))
        let original = try PGP.Signature.parse(packets: packets)
        for index in 0..<4000 {
            var rng = SplitMix64(seed: Self.baseSeed &+ 2 << 32 &+ UInt64(index))
            let mutant = Self.mutate(packets, &rng)
            guard let signature = try? PGP.Signature.parse(packets: mutant),
                let check = try? PGP.Check(signature, expecting: 0x00, keys: key, now: pgpGoldenNow), (try? check.verify(file)) != nil
            else { continue }
            #expect(signature == original, "seed 2 index \(index) was accepted with a different signature")
        }
    }

    // MARK: Original signature, mutated file

    @Test(arguments: [0, 1])
    func aMutatedFileIsNeverAccepted(vendor: Int) throws {
        let (armored, data, pinned) =
            vendor == 0
            ? (SignedVendorFiles.debianSignature, SignedVendorFiles.debianChecksums, PGP.PinnedKeys.debianCD)
            : (SignedVendorFiles.ubuntuSignature, SignedVendorFiles.ubuntuChecksums, PGP.PinnedKeys.ubuntuCDImage)
        let check = try PGP.Check.detached(Array(armored.utf8), keys: keys(pinned), now: pgpGoldenNow)
        let file = Array(data.utf8)
        var accepted = 0
        for index in 0..<2000 {
            var rng = SplitMix64(seed: Self.baseSeed &+ UInt64(3 + vendor) << 32 &+ UInt64(index))
            if (try? check.verify(Self.mutate(file, &rng))) != nil { accepted += 1 }
        }
        #expect(accepted == 0, "\(accepted) mutated files verified")
    }

    // MARK: Mutated cleartext message

    @Test func aMutatedClearSignedMessageNeverYieldsTextThatWasNotSigned() throws {
        let key = try keys(PGP.PinnedKeys.fedora44)
        let document = Array(SignedVendorFiles.fedoraChecksum.utf8)
        let original = try PGP.Check.verifyClearSigned(document, keys: key, now: pgpGoldenNow)
        var accepted = 0
        for index in 0..<4000 {
            var rng = SplitMix64(seed: Self.baseSeed &+ 5 << 32 &+ UInt64(index))
            guard let text = try? PGP.Check.verifyClearSigned(Self.mutate(document, &rng), keys: key, now: pgpGoldenNow) else { continue }
            accepted += 1
            #expect(text == original, "seed 5 index \(index) yielded text that differs from the signed text")
        }
        #expect(accepted < 4000)
    }

    // MARK: Arbitrary bytes

    @Test func arbitraryBytesNeverTrapAndNeverVerify() throws {
        let key = try keys(PGP.PinnedKeys.debianCD)
        for index in 0..<3000 {
            var rng = SplitMix64(seed: Self.baseSeed &+ 6 << 32 &+ UInt64(index))
            let bytes = Self.randomBytes(&rng, count: Int.random(in: 0...1500, using: &rng))
            _ = try? PGP.Armor.decodeSignature(bytes)
            _ = try? PGP.Armor.decodeClearSigned(bytes)
            _ = try? PGP.Signature.parse(packets: bytes)
            #expect((try? PGP.Check.detached(bytes, keys: key, now: pgpGoldenNow)) == nil, "seed 6 index \(index)")
            #expect((try? PGP.Check.verifyClearSigned(bytes, keys: key, now: pgpGoldenNow)) == nil, "seed 6 index \(index)")
        }
    }

    @Test func randomBodiesInsideValidPacketHeadersNeverTrapAndNeverVerify() throws {
        let key = try keys(PGP.PinnedKeys.debianCD)
        let real = try PGP.Armor.decodeSignature(Array(SignedVendorFiles.debianSignature.utf8))
        for index in 0..<3000 {
            var rng = SplitMix64(seed: Self.baseSeed &+ 7 << 32 &+ UInt64(index))
            // A genuine header and version-4 prefix, then noise: the deepest the parser goes without a real signature.
            let length = Int.random(in: 0...700, using: &rng)
            let prefix = Array(real[3..<3 + Int.random(in: 0...12, using: &rng)])
            let body = Array((prefix + Self.randomBytes(&rng, count: length)).prefix(length))
            let packet = TestSigner.packet(body, style: TestSigner.PacketStyle.allCases.randomElement(using: &rng) ?? .old)
            if let signature = try? PGP.Signature.parse(packets: packet) {
                #expect(
                    (try? PGP.Check(signature, expecting: 0x00, keys: key, now: pgpGoldenNow).verify([0])) == nil, "seed 7 index \(index)")
            }
        }
    }
}
