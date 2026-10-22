import Foundation

/// Downloads a small file with a size cap. The app's fetcher is `Fetch.fetchSmall`; tests pass one that serves fixtures.
typealias SmallFetch = @Sendable (_ url: URL, _ limit: Int) async throws -> Data

/// What a provider takes from its checksum file once the file's trust is settled.
struct VouchedChecksum: Sendable {
    /// The text the provider may read digests from: all of the file when only its host vouches for it, only the signed
    /// text when a signature does.
    var text: String
    /// A signature over the installer itself, vetted already, to be checked against the downloaded file.
    var imageSignature: PGP.Check?
}

/// What vouches for the checksum a provider publishes. Providers whose vendor key is pinned are signed; every other
/// provider says so explicitly with `HTTPSOnlyTrust`. A signed provider never falls back to HTTPS alone: a missing,
/// malformed, expired or wrongly made signature throws `SetupError.signatureRejected`.
protocol ChecksumTrust: Sendable {
    /// Whether the vendor signs each installer on its own, some time after publishing it (Alpine). A provider with such a trust
    /// takes the newest release whose signature exists; one whose trust signs a list does not walk back.
    var signsEachImage: Bool { get }

    /// - Parameters:
    ///   - checksumFile: The checksum file as downloaded.
    ///   - checksumURL: Where it came from; a detached signature sits next to it.
    ///   - imageURL: Where the installer will be downloaded from; a signature over the installer sits next to it.
    ///   - now: The time signatures are judged by.
    ///   - fetch: How signature files are downloaded.
    /// - Returns: The text digests may be read from, and the installer's signature when the vendor signs the installer.
    /// - Throws: `SetupError.signatureRejected` when a signature is needed and missing, malformed, untrusted or wrong.
    func vouch(
        for checksumFile: Data, at checksumURL: URL, image imageURL: URL, now: Date, fetch: SmallFetch
    ) async throws -> VouchedChecksum
}

extension ChecksumTrust {
    var signsEachImage: Bool { false }
}

/// The checksum file is believed because it came over HTTPS from the vendor's own host; nothing signs it or the installer
/// that the app checks.
struct HTTPSOnlyTrust: ChecksumTrust {
    func vouch(
        for checksumFile: Data, at checksumURL: URL, image imageURL: URL, now: Date, fetch: SmallFetch
    ) async throws -> VouchedChecksum {
        VouchedChecksum(text: try LinuxProvider.text(of: checksumFile, at: checksumURL))
    }
}

/// The vendor signs the checksum file, either in a detached file next to it or inline as a cleartext-signed message, and
/// only text the pinned key signed is read.
struct SignedChecksumTrust: ChecksumTrust {
    enum Placement: Sendable {
        /// `<checksum file>.<suffix>`, holding an armored signature over the whole checksum file.
        case detached(suffix: String)
        /// The checksum file is itself a cleartext-signed message.
        case cleartext
    }

    var placement: Placement
    var keys: [PGP.PinnedKey]

    func vouch(
        for checksumFile: Data, at checksumURL: URL, image imageURL: URL, now: Date, fetch: SmallFetch
    ) async throws -> VouchedChecksum {
        let name = checksumURL.lastPathComponent
        let trusted = try SignatureSupport.keys(keys, for: name)
        switch placement {
        case .cleartext:
            let text = try SignatureSupport.refusing(name) { () throws(PGP.Failure) in
                try PGP.Check.verifyClearSigned(Array(checksumFile), keys: trusted, now: now)
            }
            return VouchedChecksum(text: try LinuxProvider.text(of: Data(text), at: checksumURL))
        case .detached(let suffix):
            let armored = try await SignatureSupport.signature(at: checksumURL.appendingPathExtension(suffix), fetch: fetch)
            try SignatureSupport.refusing(name) { () throws(PGP.Failure) in
                try PGP.Check.detached(armored, keys: trusted, now: now).verify(Array(checksumFile))
            }
            return VouchedChecksum(text: try LinuxProvider.text(of: checksumFile, at: checksumURL))
        }
    }
}

/// The vendor signs the installer itself, not its checksum file (Alpine). The signature is fetched and vetted before the
/// download; `ImageStore` checks it against the downloaded file, which is the only thing that proves the file. The checksum
/// file still supplies the SHA-256 that is checked as well.
struct SignedImageTrust: ChecksumTrust {
    /// The signature is `<installer>.<suffix>`.
    var suffix: String
    var keys: [PGP.PinnedKey]

    var signsEachImage: Bool { true }

    func vouch(
        for checksumFile: Data, at checksumURL: URL, image imageURL: URL, now: Date, fetch: SmallFetch
    ) async throws -> VouchedChecksum {
        let name = imageURL.lastPathComponent
        let trusted = try SignatureSupport.keys(keys, for: name)
        let armored = try await SignatureSupport.signature(
            at: imageURL.appendingPathExtension(suffix), fetch: fetch, reportsMissing: true)
        let check = try SignatureSupport.refusing(name) { () throws(PGP.Failure) in
            try PGP.Check.detached(armored, keys: trusted, now: now)
        }
        return VouchedChecksum(text: try LinuxProvider.text(of: checksumFile, at: checksumURL), imageSignature: check)
    }
}

/// The steps the signed trusts share.
private enum SignatureSupport {
    /// The pinned keys as verifiable keys.
    /// - Throws: `SetupError.signatureRejected` if there is none (a release the app has no key for) or a constant is damaged.
    static func keys(_ pinned: [PGP.PinnedKey], for file: String) throws(SetupError) -> [PGP.RSAPublicKey] {
        guard !pinned.isEmpty else { throw .signatureRejected(file: file, reason: "this app has no signing key pinned for it") }
        return try pinned.map { key throws(SetupError) in
            do { return try key.publicKey() } catch { throw .signatureRejected(file: file, reason: error.localizedDescription) }
        }
    }

    /// Downloads a signature file from a host the download policy allows, capped at `PGP.maximumSignatureSize`.
    /// - Parameters:
    ///   - url: Where the signature is; it must pass the download policy.
    ///   - fetch: How the file is downloaded.
    ///   - reportsMissing: Answers an HTTP 404 with `SetupError.signatureNotPublished` instead of a rejection, for a caller
    ///     that can take an older release. Every other failure is a rejection either way.
    /// - Returns: The signature file's bytes.
    /// - Throws: `SetupError.signatureRejected` if it cannot be had, so a missing signature never reads as "no signature needed".
    static func signature(at url: URL, fetch: SmallFetch, reportsMissing: Bool = false) async throws -> [UInt8] {
        _ = try DownloadPolicy.validate(url)
        do {
            return Array(try await fetch(url, PGP.maximumSignatureSize))
        } catch {
            try Task.checkCancellation()
            if reportsMissing, case SetupError.badResponse(_, 404) = error {
                throw SetupError.signatureNotPublished(file: url.deletingPathExtension().lastPathComponent)
            }
            throw SetupError.signatureRejected(
                file: url.deletingPathExtension().lastPathComponent,
                reason: "the signature file \(url.lastPathComponent) could not be downloaded (\(error.localizedDescription))")
        }
    }

    /// Runs `check` and turns a `PGP.Failure` into the error that names the refused file.
    static func refusing<T>(_ file: String, _ check: () throws(PGP.Failure) -> T) throws(SetupError) -> T {
        do { return try check() } catch { throw .signatureRejected(file: file, reason: error.localizedDescription) }
    }
}
