import CryptoKit
import Foundation
import Security

extension PGP {
    /// A version 4 RSA public key as the pinned vendor keys are stored: the two integers and the creation time, which are
    /// everything the key's fingerprint covers.
    struct RSAPublicKey: Equatable, Sendable {
        /// Big-endian, without leading zeros.
        let modulus: [UInt8]
        /// Big-endian, without leading zeros.
        let exponent: [UInt8]
        /// Seconds since 1970.
        let created: UInt32
        /// The 20-byte version 4 fingerprint of the integers and the creation time.
        let fingerprint: [UInt8]

        /// - Throws: `Failure.invalidKey` for a modulus under 2048 or over 8192 bits, one that is even, an exponent that is even or
        ///   below 3, or an integer with a leading zero byte.
        init(modulus: [UInt8], exponent: [UInt8], created: UInt32) throws(Failure) {
            guard (256...1024).contains(modulus.count), modulus.first != 0, modulus.last.map({ $0 & 1 == 1 }) == true,
                let first = exponent.first, first != 0, exponent.last.map({ $0 & 1 == 1 }) == true, exponent != [1],
                exponent.count <= modulus.count
            else { throw .invalidKey }
            self.modulus = modulus
            self.exponent = exponent
            self.created = created
            fingerprint = Self.fingerprint(modulus: modulus, exponent: exponent, created: created)
        }

        /// The version 4 fingerprint of an RSA key: SHA-1 over `0x99`, the length of the key body, and the body (version,
        /// creation time, algorithm 1, modulus and exponent as multiprecision integers). SHA-1 only names the key here; no
        /// signature depends on its strength, and `Check` still compares every byte of the pinned modulus.
        static func fingerprint(modulus: [UInt8], exponent: [UInt8], created: UInt32) -> [UInt8] {
            let time = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: created >> UInt32($0)) }
            let body: [UInt8] = [4] + time + [1] + multiprecision(modulus) + multiprecision(exponent)
            var hasher = Insecure.SHA1()
            hasher.update(data: [0x99, UInt8(truncatingIfNeeded: body.count >> 8), UInt8(truncatingIfNeeded: body.count)])
            hasher.update(data: body)
            return Array(hasher.finalize())
        }

        private static func multiprecision(_ integer: [UInt8]) -> [UInt8] {
            let bits = integer.count * 8 - (integer.first?.leadingZeroBitCount ?? 8)
            return [UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)] + integer
        }

        /// RSASSA-PKCS1-v1_5 verification of `signature` over `digest`, which `hash` made.
        /// - Throws: `Failure.badSignature` unless the signature is a valid integer below the modulus that Security.framework
        ///   accepts; `Failure.invalidKey` if the framework refuses the key.
        func verify(digest: [UInt8], hash: HashAlgorithm, signature: [UInt8]) throws(Failure) {
            guard signature.count <= modulus.count else { throw .badSignature }
            let padded = [UInt8](repeating: 0, count: modulus.count - signature.count) + signature
            guard padded.lexicographicallyPrecedes(modulus) else { throw .badSignature }
            let verified = SecKeyVerifySignature(try secKey(), hash.secKeyAlgorithm, Data(digest) as CFData, Data(padded) as CFData, nil)
            guard verified else { throw .badSignature }
        }

        private func secKey() throws(Failure) -> SecKey {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ]
            guard let key = SecKeyCreateWithData(Data(publicKeyDER) as CFData, attributes as CFDictionary, nil) else { throw .invalidKey }
            return key
        }

        /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
        private var publicKeyDER: [UInt8] {
            let body = Self.derInteger(modulus) + Self.derInteger(exponent)
            return [0x30] + Self.derLength(body.count) + body
        }

        private static func derInteger(_ magnitude: [UInt8]) -> [UInt8] {
            // A leading zero keeps a value whose top bit is set from reading as negative.
            let content = (magnitude.first ?? 0) & 0x80 != 0 ? [0] + magnitude : magnitude
            return [0x02] + derLength(content.count) + content
        }

        private static func derLength(_ length: Int) -> [UInt8] {
            guard length >= 0x80 else { return [UInt8(length)] }
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }.drop { $0 == 0 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
    }

    /// A vendor key built into the app, as constants that `publicKey()` checks against the fingerprint before they are used.
    struct PinnedKey: Equatable, Sendable {
        /// Who the key belongs to, in the words of the vendor's own key file.
        var owner: String
        /// The 40 hexadecimal digits the vendor publishes, in uppercase.
        var fingerprint: String
        /// Seconds since 1970 that the key was made, which the fingerprint covers.
        var created: UInt32
        var modulus: String
        var exponent: String

        /// The key these constants describe.
        /// - Throws: `Failure.invalidKey` unless the constants are valid hexadecimal that hash to exactly `fingerprint`, so a
        ///   damaged or altered constant can never verify anything.
        func publicKey() throws(Failure) -> RSAPublicKey {
            guard let modulus = PGP.bytes(hex: modulus), let exponent = PGP.bytes(hex: exponent) else { throw .invalidKey }
            let key = try RSAPublicKey(modulus: modulus, exponent: exponent, created: created)
            guard key.fingerprint.hexString.uppercased() == fingerprint else { throw .invalidKey }
            return key
        }
    }
}
