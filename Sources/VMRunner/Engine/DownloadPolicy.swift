import Foundation
import RegexBuilder
import os

/// Where downloads may come from and what they may be called on disk. Catalog data (ipsw.me, mirror
/// listings) is remote input: a compromised or spoofed response must not be able to point the app at
/// another host, a plain-HTTP URL, or a path outside the image cache.
enum DownloadPolicy {
    /// The hosts that serve installers, listings, checksums and signatures, each named exactly. A suffix such as
    /// `debian.org` would also admit hosts that serve user content (`salsa.debian.org`, `people.debian.org`) and any
    /// subdomain Apple or a vendor hands to a third party, so no entry here covers its subdomains. Each Linux provider's
    /// host must be added here before it moves from `LinuxCatalog.candidates` to `images`.
    static let allowedHosts: Set<String> = [
        restoreImageHost, "mirror.stream.centos.org", "deb.debian.org", "cdimage.debian.org", "dl-cdn.alpinelinux.org",
        "cdimage.ubuntu.com",
    ]

    /// The one host that serves macOS restore images, for `.latestMac` and for every ipsw.me entry.
    static let restoreImageHost = "updates.cdn-apple.com"

    /// The ipsw.me catalog API: asked for metadata only, never for a file to download.
    static let catalogHost = "api.ipsw.me"

    /// Whether `url` may be an installer, a listing, a checksum file or a signature: HTTPS, an exactly named host, the
    /// default port and no credentials.
    static func validate(_ url: URL) throws(SetupError) -> URL {
        try check(url, hosts: allowedHosts)
    }

    /// Whether `url` may be fetched as a small document: everything `validate` accepts, and the ipsw.me catalog.
    static func validateMetadata(_ url: URL) throws(SetupError) -> URL {
        try check(url, hosts: allowedHosts.union([catalogHost]))
    }

    /// Whether `url`, taken from the ipsw.me catalog, may be downloaded as a restore image: Apple's update server only,
    /// and a file named `*.ipsw`.
    static func validateRestoreImage(_ url: URL) throws(SetupError) -> URL {
        _ = try check(url, hosts: [restoreImageHost])
        guard try cacheFileName(for: url).hasSuffix(".ipsw") else { throw .untrustedURL(url) }
        return url
    }

    private static func check(_ url: URL, hosts: Set<String>) throws(SetupError) -> URL {
        guard url.scheme == "https", url.user() == nil, url.password() == nil, url.port == nil || url.port == 443,
            let host = url.host()?.lowercased(), hosts.contains(host)
        else { throw .untrustedURL(url) }
        return url
    }

    /// The last path component, if it is a plain file name: no separators, no leading dot, bounded length.
    static func cacheFileName(for url: URL) throws(SetupError) -> String {
        let name = url.lastPathComponent
        // The bytes are judged, not the characters: Swift treats a string and its Unicode normalization (the Kelvin sign
        // and `K`) as equal, and a file name must be exactly the ASCII it appears to be.
        let bytes = Array(name.utf8)
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        }
        guard let first = bytes.first, bytes.count <= 200, isAlphanumeric(first),
            bytes.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") })
        else { throw .unsafeFileName(name) }
        return name
    }

    /// Mac model identifiers look like `Mac14,15`; anything else would alter the catalog URL's path.
    static func validateMachineModel(_ identifier: String) throws(SetupError) -> String {
        let modelIdentifier = Regex {
            Repeat(1...24) { .asciiAlphanumeric }
            ","
            Repeat(1...4) { .asciiDigit }
        }
        guard identifier.wholeMatch(of: modelIdentifier) != nil else { throw .invalidMachineModel(identifier) }
        return identifier
    }
}

/// Refuses redirects that leave the download policy.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    /// Whether the ipsw.me catalog host is acceptable, as for a small document but not for a download.
    private let metadata: Bool

    init(metadata: Bool = false) { self.metadata = metadata }

    /// The request to follow, or nil to stop at the redirect response.
    static func allowed(_ request: URLRequest, metadata: Bool = false) -> URLRequest? {
        let validate = metadata ? DownloadPolicy.validateMetadata : DownloadPolicy.validate
        guard let url = request.url, (try? validate(url)) != nil else {
            Log.network.error("Blocked a redirect to a disallowed location")
            return nil
        }
        return request
    }

    // The completion-handler form: the `async` variant crashes the Swift 6.4 compiler's Objective-C thunk
    // emission when NonisolatedNonsendingByDefault is on.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.allowed(request, metadata: metadata))
    }
}
