import Foundation

enum SetupError: LocalizedError {
    case checksumMismatch(file: String, expected: String, actual: String)
    case badResponse(URL, Int)
    case untrustedURL(URL)
    case unsafeFileName(String)
    case responseTooLarge(URL)
    case invalidMachineModel(String)
    case unsupportedHost(String)
    case missingFile(String)
    /// A cached or attached file is a link or another kind of entry where a regular file must be.
    case notARegularFile(String)
    /// A checksum that is not SHA-256 cannot vouch for a file.
    case weakChecksum(String)
    /// `file` is a genuine release but older than `oldest`, the oldest this version of the app accepts.
    case releaseTooOld(file: String, oldest: String)
    /// The vendor has not published the signature of `file` (HTTP 404), as opposed to a signature that cannot be had or trusted.
    case signatureNotPublished(file: String)
    /// Every release from `oldest` up that the vendor lists lacks its signature so far; `unsigned` names them, newest first.
    case noSignedRelease(oldest: String, unsigned: [String])
    /// The OpenPGP signature that should vouch for `file` is missing, malformed or wrong; `reason` completes "because ...".
    case signatureRejected(file: String, reason: String)
    case rosettaUnavailable

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let file, let expected, let actual):
            "Checksum mismatch for \(file): expected \(expected), got \(actual)."
        case .badResponse(let url, let status):
            "HTTP \(status) from \(url.host() ?? url.absoluteString)."
        case .untrustedURL(let url):
            "Refusing to download from \(url.host() ?? url.absoluteString): "
                + "only HTTPS from the hosts of Apple and the offered Linux distributions is allowed."
        case .unsafeFileName(let name):
            "Refusing a download with an unsafe file name: \(name)"
        case .responseTooLarge(let url):
            "The response from \(url.host() ?? url.absoluteString) is larger than expected."
        case .invalidMachineModel(let identifier):
            "“\(identifier)” isn't a Mac model identifier like Mac14,15."
        case .unsupportedHost(let reason):
            reason
        case .missingFile(let path):
            "File not found: \(path)"
        case .signatureNotPublished(let file):
            "The vendor has not published an OpenPGP signature for \(file) yet."
        case .noSignedRelease(let oldest, let unsigned):
            "No release from \(oldest) up has a published OpenPGP signature yet"
                + (unsigned.isEmpty ? "" : " (\(unsigned.joined(separator: ", ")) has none)")
                + ". VMRunner does not install an image it cannot check; try again later."
        case .releaseTooOld(let file, let oldest):
            "Refusing \(file): it is older than the oldest release this version of VMRunner accepts (\(oldest)). "
                + "The listing may be out of date or tampered with; update VMRunner if a newer release exists."
        case .weakChecksum(let name):
            "Refusing \(name): its checksum is not a SHA-256, and a weaker one cannot vouch for a download."
        case .notARegularFile(let name):
            "Refusing \(name): it is a link or another kind of entry, not a regular file."
        case .signatureRejected(let file, let reason):
            "Refusing \(file): its OpenPGP signature cannot be trusted, because \(reason)."
        case .rosettaUnavailable:
            "Rosetta for Linux isn't installed. Install it from the VM's settings."
        }
    }
}
