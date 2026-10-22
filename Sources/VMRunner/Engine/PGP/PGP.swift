import CryptoKit
import Foundation
import Security

/// A strict, verify-only OpenPGP reader for the one shape vendors use to sign installers: a version 4 signature made with an
/// RSA key that the app pins (ADR-0023). Nothing else is accepted: another signature version, another key algorithm, a weak
/// hash, a signature the pinned key did not make, or any byte the reader does not understand fails closed with a
/// `PGP.Failure`. It cannot create signatures, read key rings or follow trust chains.
enum PGP {
    /// The most bytes of signature the app downloads. Real ones are under 1 KiB.
    static let maximumSignatureSize = 16 << 10

    /// `text` (ASCII hexadecimal, either case) as bytes; nil for an odd length or a character that is not a hex digit.
    static func bytes(hex text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Why a signature was refused. Every case reads as one sentence for the user, so a failed download says what was wrong.
    enum Failure: LocalizedError, Equatable, Sendable {
        case malformedArmor(String)
        case armorChecksum
        case malformedSignature(String)
        case signatureCount(Int)
        case unsupportedVersion(UInt8)
        case unsupportedPublicKeyAlgorithm(UInt8)
        case unsupportedHashAlgorithm(UInt8)
        case unsupportedType(UInt8)
        case unknownCriticalSubpacket(UInt8)
        /// The fingerprint, in uppercase hexadecimal, of a key that is not pinned for this file.
        case unpinnedSigner(String)
        case notYetValid
        case expired
        case keyExpired
        case predatesKey
        case invalidKey
        case badSignature

        var errorDescription: String? {
            switch self {
            case .malformedArmor(let reason): "the signature text is malformed (\(reason))"
            case .armorChecksum: "the signature text is damaged (its checksum line does not match)"
            case .malformedSignature(let reason): "the signature is malformed (\(reason))"
            case .signatureCount(let count): "the file carries \(count) signatures, not exactly one"
            case .unsupportedVersion(let version): "it is a version \(version) signature, and only version 4 is accepted"
            case .unsupportedPublicKeyAlgorithm(let algorithm): "it uses public-key algorithm \(algorithm), and only RSA is accepted"
            case .unsupportedHashAlgorithm(let algorithm):
                "it uses hash algorithm \(algorithm), and only SHA-256, SHA-384 and SHA-512 are accepted"
            case .unsupportedType(let type): "it is a signature of type \(type), which does not fit this file"
            case .unknownCriticalSubpacket(let type): "it has a critical subpacket of type \(type), which this app does not understand"
            case .unpinnedSigner(let fingerprint): "it was made by key \(fingerprint), which is not pinned for this download"
            case .notYetValid: "it claims to have been made in the future (check the clock of this Mac)"
            case .expired: "it has expired"
            case .keyExpired: "the pinned key that made it has expired; an update of this app pins the vendor's next key"
            case .predatesKey: "it claims to be older than the key that made it"
            case .invalidKey: "the pinned key is damaged"
            case .badSignature: "it does not match the file, so the file or its signature was altered"
            }
        }
    }

    /// The hash algorithms a signature may use.
    enum HashAlgorithm: UInt8, Sendable {
        case sha256 = 8
        case sha384 = 9
        case sha512 = 10

        /// The name a cleartext message lists in its `Hash:` header.
        var headerName: String {
            switch self {
            case .sha256: "SHA256"
            case .sha384: "SHA384"
            case .sha512: "SHA512"
            }
        }

        /// RSASSA-PKCS1-v1_5 over a digest this algorithm made.
        var secKeyAlgorithm: SecKeyAlgorithm {
            switch self {
            case .sha256: .rsaSignatureDigestPKCS1v15SHA256
            case .sha384: .rsaSignatureDigestPKCS1v15SHA384
            case .sha512: .rsaSignatureDigestPKCS1v15SHA512
            }
        }
    }

    /// A running hash of what a signature covers, so a large file can be fed through in chunks.
    struct Digest: Sendable {
        private enum State {
            case sha256(SHA256)
            case sha384(SHA384)
            case sha512(SHA512)
        }

        private var state: State

        init(_ algorithm: HashAlgorithm) {
            switch algorithm {
            case .sha256: state = .sha256(SHA256())
            case .sha384: state = .sha384(SHA384())
            case .sha512: state = .sha512(SHA512())
            }
        }

        mutating func update(_ bytes: some DataProtocol) {
            switch state {
            case .sha256(var hasher):
                hasher.update(data: bytes)
                state = .sha256(hasher)
            case .sha384(var hasher):
                hasher.update(data: bytes)
                state = .sha384(hasher)
            case .sha512(var hasher):
                hasher.update(data: bytes)
                state = .sha512(hasher)
            }
        }

        /// The digest of everything fed so far; the running hash itself is not consumed.
        func finalized() -> [UInt8] {
            switch state {
            case .sha256(let hasher): Array(hasher.finalize())
            case .sha384(let hasher): Array(hasher.finalize())
            case .sha512(let hasher): Array(hasher.finalize())
            }
        }
    }

    /// A bounds-checked cursor over bytes of a signature, so no parser here indexes an array by a length it has not checked.
    struct ByteReader {
        private let bytes: [UInt8]
        private var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { position == bytes.count }

        mutating func byte() throws(Failure) -> UInt8 {
            guard position < bytes.count else { throw .malformedSignature("the data ends early") }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func take(_ count: Int) throws(Failure) -> [UInt8] {
            guard count >= 0, count <= bytes.count - position else { throw .malformedSignature("a length runs past the data") }
            defer { position += count }
            return Array(bytes[position..<position + count])
        }

        mutating func uint16() throws(Failure) -> Int {
            try Int(byte()) << 8 | Int(byte())
        }

        mutating func uint32() throws(Failure) -> Int {
            try uint16() << 16 | uint16()
        }
    }
}
