import Foundation

extension PGP {
    /// A signature that passed every test except the public-key operation: it is made by a pinned key, of the expected type, and
    /// valid at the time asked. `verify` then proves that the key signed exactly the bytes handed to it.
    ///
    /// Splitting the two lets a vendor's signature over a large installer be fetched and vetted before the download starts, and
    /// checked after it, with the file streamed through a `Digest` instead of read into memory.
    struct Check: Equatable, Sendable {
        let signature: Signature
        let key: RSAPublicKey

        /// - Parameters:
        ///   - signature: The parsed signature.
        ///   - type: `0x00` for a signature over a binary file, `0x01` over canonical text; any other type is refused.
        ///   - keys: The only keys that may have signed. The issuer is taken from the signed part of the signature.
        ///   - now: The time to judge the signature by.
        /// - Throws: `Failure.unsupportedType`, `.unpinnedSigner`, `.notYetValid`, `.predatesKey` or `.expired`.
        init(_ signature: Signature, expecting type: UInt8, keys: [RSAPublicKey], now: Date) throws(Failure) {
            guard signature.type == type else { throw .unsupportedType(signature.type) }
            guard let key = keys.first(where: { $0.fingerprint == signature.issuerFingerprint }) else {
                throw .unpinnedSigner(signature.issuerFingerprint.hexString.uppercased())
            }
            guard let seconds = Int64(exactly: now.timeIntervalSince1970.rounded(.down)) else { throw .notYetValid }
            let created = Int64(signature.created)
            guard created <= seconds else { throw .notYetValid }
            guard created >= Int64(key.created) else { throw .predatesKey }
            if let lifetime = signature.expiresAfter, created + Int64(lifetime) <= seconds { throw .expired }
            self.signature = signature
            self.key = key
        }

        /// The check for an armored detached signature over a binary file.
        static func detached(_ armored: [UInt8], keys: [RSAPublicKey], now: Date) throws(Failure) -> Self {
            try Self(Signature.parse(packets: Armor.decodeSignature(armored)), expecting: 0x00, keys: keys, now: now)
        }

        /// The text of a cleartext-signed document, once the signature over exactly that text verifies.
        static func verifyClearSigned(_ document: [UInt8], keys: [RSAPublicKey], now: Date) throws(Failure) -> [UInt8] {
            let message = try Armor.decodeClearSigned(document)
            let signature = try Signature.parse(packets: message.signature)
            guard message.hashNames.contains(signature.hash.headerName) else {
                throw .malformedArmor("the Hash header does not name the hash the signature uses")
            }
            try Self(signature, expecting: 0x01, keys: keys, now: now).verify(message.canonicalText)
            return message.text
        }

        /// The start of the running hash a signed file is fed through before `verify(_:)`.
        func makeDigest() -> Digest { Digest(signature.hash) }

        /// Checks the signature over everything `digest` has been fed, which must be all of the signed file and nothing else.
        func verify(_ digest: Digest) throws(Failure) {
            var finished = digest
            finished.update(signature.trailer)
            let value = finished.finalized()
            guard value.starts(with: signature.hashPrefix) else { throw .badSignature }
            try key.verify(digest: value, hash: signature.hash, signature: signature.value)
        }

        /// Checks the signature over `file`, held in memory.
        func verify(_ file: [UInt8]) throws(Failure) {
            var digest = makeDigest()
            digest.update(file)
            try verify(digest)
        }
    }
}
