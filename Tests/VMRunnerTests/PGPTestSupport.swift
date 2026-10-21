import CryptoKit
import Foundation
import Security

@testable import VMRunner

/// The moment the tests judge signatures at: after every synthetic signature below and before any expiry.
let pgpTestNow = Date(timeIntervalSince1970: 1_800_000_000)

/// What a synthetic signature packet is made of. The defaults are a valid version 4 RSA signature with SHA-256 over a binary
/// file; a test changes the one field it wants to break.
struct SignatureDraft {
    enum Issuer {
        /// The fingerprint of the key that signs.
        case signer
        case none
        case fingerprint([UInt8])
    }

    var version: UInt8 = 4
    var type: UInt8 = 0x00
    var algorithm: UInt8 = 1
    var hash: UInt8 = 8
    var created: UInt32 = 1_750_000_000
    /// Which issuer fingerprint the hashed area carries.
    var issuer = Issuer.signer
    /// Extra encoded subpackets for the hashed area.
    var extraHashed: [[UInt8]] = []
    /// Encoded subpackets for the unhashed area.
    var unhashed: [[UInt8]] = []
    /// Replaces the creation time subpacket (for a duplicate or a missing one) when set.
    var replacingCreation: [[UInt8]]?
    /// Replaces the two hash-prefix bytes when set.
    var hashPrefix: [UInt8]?
}

/// A throwaway RSA key and a writer of version 4 signatures made with it, so each path of the verifier has a positive and a
/// negative test without a network or a vendor key. Signatures are made with the framework's message variant, which hashes the
/// message itself, so they check the verifier's own hashing independently.
struct TestSigner: @unchecked Sendable {  // immutable after init; a SecKey is a thread-safe reference
    let privateKey: SecKey
    let key: PGP.RSAPublicKey

    /// Seconds since 1970 that the synthetic key was "made".
    static let keyCreated: UInt32 = 1_700_000_000

    init(bits: Int = 2048) throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: bits]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil), let publicKey = SecKeyCopyPublicKey(privateKey),
            let der = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw PGP.Failure.invalidKey }
        self.privateKey = privateKey
        let (modulus, exponent) = try Self.integers(ofPKCS1: Array(der))
        key = try PGP.RSAPublicKey(modulus: modulus, exponent: exponent, created: Self.keyCreated)
    }

    /// The public half, for calling the framework directly.
    var publicSecKey: SecKey? { SecKeyCopyPublicKey(privateKey) }

    /// The key in the form the vendor keys are pinned in.
    var pinned: PGP.PinnedKey {
        PGP.PinnedKey(
            owner: "Test key", fingerprint: key.fingerprint.hexString.uppercased(), created: key.created,
            modulus: key.modulus.hexString, exponent: key.exponent.hexString)
    }

    // MARK: Signatures

    /// The body of a signature packet over `message`.
    func signatureBody(over message: [UInt8], _ draft: SignatureDraft = SignatureDraft()) throws -> [UInt8] {
        var hashed: [UInt8] = draft.replacingCreation?.flatMap { $0 } ?? Self.subpacket(2, Self.be32(draft.created))
        switch draft.issuer {
        case .signer: hashed += Self.subpacket(33, [4] + key.fingerprint)
        case .none: break
        case .fingerprint(let fingerprint): hashed += Self.subpacket(33, [4] + fingerprint)
        }
        hashed += draft.extraHashed.flatMap { $0 }
        let header: [UInt8] = [draft.version, draft.type, draft.algorithm, draft.hash] + Self.be16(hashed.count) + hashed
        let trailer = header + [0x04, 0xFF] + Self.be32(UInt32(header.count))
        let signed = Data(message + trailer)
        let algorithm: SecKeyAlgorithm =
            switch draft.hash {
            case 9: .rsaSignatureMessagePKCS1v15SHA384
            case 10: .rsaSignatureMessagePKCS1v15SHA512
            default: .rsaSignatureMessagePKCS1v15SHA256
            }
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, signed as CFData, nil) as Data? else {
            throw PGP.Failure.badSignature
        }
        let prefix: [UInt8]
        switch draft.hash {
        case 9: prefix = Array(SHA384.hash(data: signed).prefix(2))
        case 10: prefix = Array(SHA512.hash(data: signed).prefix(2))
        default: prefix = Array(SHA256.hash(data: signed).prefix(2))
        }
        let unhashed = draft.unhashed.flatMap { $0 }
        return header + Self.be16(unhashed.count) + unhashed + (draft.hashPrefix ?? prefix) + Self.mpi(Array(signature))
    }

    /// An armored detached signature over `message`.
    func detachedSignature(over message: [UInt8], _ draft: SignatureDraft = SignatureDraft(), style: PacketStyle = .old) throws -> [UInt8] {
        Self.armor(Self.packet(try signatureBody(over: message, draft), style: style))
    }

    /// A cleartext-signed message of `lines`, signed the way a signer does: trailing blanks cut, lines joined by CRLF.
    func clearSigned(_ lines: [String], hashHeader: String = "SHA256", type: UInt8 = 0x01, _ draft: SignatureDraft = SignatureDraft())
        throws -> [UInt8]
    {
        var draft = draft
        draft.type = type
        let canonical = Array(lines.map { Self.trimmingTrailingBlanks(Array($0.utf8)) }.joined(separator: [0x0D, 0x0A]))
        let signature = Self.armor(Self.packet(try signatureBody(over: canonical, draft)))
        let escaped = lines.map { $0.hasPrefix("-") ? "- " + $0 : $0 }
        let text = "-----BEGIN PGP SIGNED MESSAGE-----\nHash: \(hashHeader)\n\n" + escaped.joined(separator: "\n") + "\n"
        return Array(text.utf8) + signature
    }

    // MARK: Encoding

    static func trimmingTrailingBlanks(_ line: [UInt8]) -> [UInt8] {
        var end = line.count
        while end > 0, line[end - 1] == 0x20 || line[end - 1] == 0x09 { end -= 1 }
        return Array(line[..<end])
    }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }

    static func be32(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) } }

    /// A subpacket with a one-byte length (bodies here are short).
    static func subpacket(_ type: UInt8, _ body: [UInt8], critical: Bool = false) -> [UInt8] {
        [UInt8(body.count + 1), type | (critical ? 0x80 : 0)] + body
    }

    /// A multiprecision integer: the bit count, then the bytes without leading zeros.
    static func mpi(_ bytes: [UInt8]) -> [UInt8] {
        let trimmed = Array(bytes.drop { $0 == 0 })
        return be16(trimmed.count * 8 - (trimmed.first?.leadingZeroBitCount ?? 8)) + trimmed
    }

    /// How a packet header spells its length.
    enum PacketStyle: CaseIterable {
        /// The old format with a two-byte length.
        case old
        /// The old format with a four-byte length.
        case oldFourByte
        /// The new format, with the shortest length that fits (two octets for a signature this size).
        case new
        /// The new format with a five-octet length.
        case newFiveOctet
    }

    /// A signature packet around `body`.
    static func packet(_ body: [UInt8], style: PacketStyle = .old) -> [UInt8] {
        let count = body.count
        switch style {
        case .old: return [0x89] + be16(count) + body
        case .oldFourByte: return [0x8A] + be32(UInt32(count)) + body
        case .new:
            if count < 192 { return [0xC2, UInt8(count)] + body }
            return [0xC2, UInt8(((count - 192) >> 8) + 192), UInt8((count - 192) & 0xFF)] + body
        case .newFiveOctet: return [0xC2, 0xFF] + be32(UInt32(count)) + body
        }
    }

    /// An armored block with a checksum line, 64 characters to a line.
    static func armor(_ bytes: [UInt8], label: String = "SIGNATURE", checksum: Bool = true) -> [UInt8] {
        let encoded = Array(Data(bytes).base64EncodedString().utf8)
        var text = "-----BEGIN PGP \(label)-----\n\n"
        for start in stride(from: 0, to: encoded.count, by: 64) {
            text += utf8String(encoded[start..<min(start + 64, encoded.count)]) + "\n"
        }
        if checksum {
            let crc = PGP.Armor.crc24(bytes)
            text += "=" + Data([UInt8(crc >> 16), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]).base64EncodedString() + "\n"
        }
        return Array((text + "-----END PGP \(label)-----\n").utf8)
    }

    // MARK: DER

    /// The two integers of a PKCS#1 `RSAPublicKey`, without leading zeros.
    private static func integers(ofPKCS1 der: [UInt8]) throws -> (modulus: [UInt8], exponent: [UInt8]) {
        var index = 0
        /// Reads a tag and a definite length at `index` and leaves `index` at the content.
        func header(_ tag: UInt8) throws -> Int {
            guard index + 2 <= der.count, der[index] == tag else { throw PGP.Failure.invalidKey }
            var length = Int(der[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 3, index + count <= der.count else { throw PGP.Failure.invalidKey }
                length = der[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard index + length <= der.count else { throw PGP.Failure.invalidKey }
            return length
        }
        func integer() throws -> [UInt8] {
            let length = try header(0x02)
            defer { index += length }
            return Array(der[index..<index + length].drop { $0 == 0 })
        }
        _ = try header(0x30)
        return (try integer(), try integer())
    }
}

/// A small deterministic generator (SplitMix64), so a failing fuzz case reproduces from its seed alone.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// One throwaway key for the whole suite: making an RSA key costs far more than every other step of a test.
enum SharedSigner {
    private static let made = Result { try TestSigner() }

    static func get() throws -> TestSigner { try made.get() }
}

/// `bytes` as UTF-8 text; the fixtures are ASCII, so a failure to decode shows up as a failed comparison.
func utf8String(_ bytes: some Sequence<UInt8>) -> String { String(bytes: bytes, encoding: .utf8) ?? "" }
