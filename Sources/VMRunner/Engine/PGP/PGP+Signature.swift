extension PGP {
    /// A version 4 RSA signature packet (RFC 4880 section 5.2.3), reduced to what a verifier may trust.
    ///
    /// Only the hashed subpacket area is read: the unhashed area is not covered by the signature, so anything in it, the
    /// issuer key ID included, could have been put there by whoever served the file.
    struct Signature: Equatable, Sendable {
        /// `0x00` for a binary document, `0x01` for canonical text.
        var type: UInt8
        var hash: HashAlgorithm
        /// Seconds since 1970 that the signer claims.
        var created: UInt32
        /// Seconds after `created` that the signature lasts; nil for a signature that does not expire.
        var expiresAfter: UInt32?
        /// The 20-byte fingerprint of the signing key, from the hashed area.
        var issuerFingerprint: [UInt8]
        /// The version, type, algorithms, subpacket length and hashed subpackets as they were signed: the first part of the
        /// trailer that is hashed after the document.
        var hashedHeader: [UInt8]
        /// The first two bytes of the digest, which a verifier can compare before doing any public-key work.
        var hashPrefix: [UInt8]
        /// The RSA signature as a big-endian integer without leading zeros.
        var value: [UInt8]

        /// What is hashed after the document: the signed header, then `0x04 0xFF` and its length.
        var trailer: [UInt8] {
            let length = hashedHeader.count
            return hashedHeader + [0x04, 0xFF] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }
        }

        /// The one signature packet in `packets`.
        /// - Throws: `Failure` for any other packet, for no signature or several, and for anything malformed.
        static func parse(packets: [UInt8]) throws(Failure) -> Self {
            var reader = ByteReader(packets)
            var bodies: [[UInt8]] = []
            while !reader.isAtEnd { bodies.append(try packetBody(&reader)) }
            guard let body = bodies.first else { throw .malformedSignature("the file has no packet") }
            guard bodies.count == 1 else { throw .signatureCount(bodies.count) }
            return try parse(body: body)
        }

        // MARK: Packet framing

        /// The body of the signature packet that starts at `reader`. Both packet formats are read; a partial or indefinite length
        /// is refused, because a signature never needs one.
        private static func packetBody(_ reader: inout ByteReader) throws(Failure) -> [UInt8] {
            let header = try reader.byte()
            guard header & 0x80 != 0 else { throw .malformedSignature("a packet header without its marker bit") }
            let tag: UInt8
            let length: Int
            if header & 0x40 != 0 {
                tag = header & 0x3F
                let first = try reader.byte()
                switch first {
                case 0..<192: length = Int(first)
                case 192..<224: length = try (Int(first) - 192) << 8 + Int(reader.byte()) + 192
                case 255: length = try reader.uint32()
                default: throw .malformedSignature("a partial packet length")
                }
            } else {
                tag = (header >> 2) & 0x0F
                switch header & 0x03 {
                case 0: length = Int(try reader.byte())
                case 1: length = try reader.uint16()
                case 2: length = try reader.uint32()
                default: throw .malformedSignature("an indefinite packet length")
                }
            }
            guard tag == 2 else { throw .malformedSignature("a packet that is not a signature (tag \(tag))") }
            return try reader.take(length)
        }

        // MARK: Packet body

        private static func parse(body: [UInt8]) throws(Failure) -> Self {
            var reader = ByteReader(body)
            let version = try reader.byte()
            guard version == 4 else { throw .unsupportedVersion(version) }
            let type = try reader.byte()
            guard type == 0x00 || type == 0x01 else { throw .unsupportedType(type) }
            let algorithm = try reader.byte()
            guard algorithm == 1 else { throw .unsupportedPublicKeyAlgorithm(algorithm) }
            let hashID = try reader.byte()
            guard let hash = HashAlgorithm(rawValue: hashID) else { throw .unsupportedHashAlgorithm(hashID) }

            let hashedLength = try reader.uint16()
            let hashedArea = try reader.take(hashedLength)
            let unhashedArea = try reader.take(try reader.uint16())
            _ = try subpackets(in: unhashedArea)  // read for its framing only; nothing in it is trusted
            let prefix = try reader.take(2)
            let value = try mpi(&reader)
            guard reader.isAtEnd else { throw .malformedSignature("bytes after the signature value") }

            let claims = try hashedClaims(in: hashedArea)
            return Self(
                type: type, hash: hash, created: claims.created, expiresAfter: claims.expiresAfter,
                issuerFingerprint: claims.fingerprint,
                hashedHeader: [version, type, algorithm, hashID, UInt8(hashedLength >> 8), UInt8(hashedLength & 0xFF)] + hashedArea,
                hashPrefix: prefix, value: value)
        }

        /// A multiprecision integer: a bit count, then exactly the bytes it needs, the first of them non-zero.
        private static func mpi(_ reader: inout ByteReader) throws(Failure) -> [UInt8] {
            let bits = try reader.uint16()
            let bytes = try reader.take((bits + 7) / 8)
            guard let first = bytes.first, first != 0, bits == bytes.count * 8 - first.leadingZeroBitCount else {
                throw .malformedSignature("a malformed integer")
            }
            return bytes
        }

        // MARK: Subpackets

        private struct Subpacket {
            var type: UInt8
            var isCritical: Bool
            var body: [UInt8]
        }

        private static func subpackets(in area: [UInt8]) throws(Failure) -> [Subpacket] {
            var reader = ByteReader(area)
            var found: [Subpacket] = []
            while !reader.isAtEnd {
                let first = Int(try reader.byte())
                let length: Int
                switch first {
                case 0..<192: length = first
                case 192..<255: length = try (first - 192) << 8 + Int(reader.byte()) + 192
                default: length = try reader.uint32()
                }
                guard length >= 1 else { throw .malformedSignature("an empty subpacket") }
                let type = try reader.byte()
                found.append(Subpacket(type: type & 0x7F, isCritical: type & 0x80 != 0, body: try reader.take(length - 1)))
            }
            return found
        }

        private struct HashedClaims {
            var created: UInt32
            var expiresAfter: UInt32?
            var fingerprint: [UInt8]
        }

        /// What the hashed area says about the signature. A critical subpacket this reader does not understand, a repeated
        /// one of those it does, a missing creation time or issuer fingerprint, and an issuer key ID that disagrees with the
        /// fingerprint are all refused.
        private static func hashedClaims(in area: [UInt8]) throws(Failure) -> HashedClaims {
            var created: UInt32?
            var expiresAfter: UInt32?
            var fingerprint: [UInt8]?
            var keyID: [UInt8]?
            for subpacket in try subpackets(in: area) {
                switch subpacket.type {
                case 2:
                    guard created == nil, let seconds = uint32(subpacket.body) else { throw .malformedSignature("a creation time") }
                    created = seconds
                case 3:
                    guard expiresAfter == nil, let seconds = uint32(subpacket.body) else { throw .malformedSignature("an expiry time") }
                    expiresAfter = seconds
                case 16:
                    guard keyID == nil, subpacket.body.count == 8 else { throw .malformedSignature("an issuer key ID") }
                    keyID = subpacket.body
                case 33:
                    guard fingerprint == nil, subpacket.body.count == 21, subpacket.body.first == 4 else {
                        throw .malformedSignature("an issuer fingerprint")
                    }
                    fingerprint = Array(subpacket.body.dropFirst())
                default:
                    if subpacket.isCritical { throw .unknownCriticalSubpacket(subpacket.type) }
                }
            }
            guard let created else { throw .malformedSignature("no creation time in the signed part") }
            guard let fingerprint else { throw .malformedSignature("no issuer fingerprint in the signed part") }
            if let keyID, keyID != Array(fingerprint.suffix(8)) {
                throw .malformedSignature("an issuer key ID that is not the fingerprint's")
            }
            return HashedClaims(created: created, expiresAfter: expiresAfter == 0 ? nil : expiresAfter, fingerprint: fingerprint)
        }

        private static func uint32(_ bytes: [UInt8]) -> UInt32? {
            bytes.count == 4 ? bytes.reduce(0) { $0 << 8 | UInt32($1) } : nil
        }
    }
}
