import Foundation

/// A DNS name rule: either one exact name or every subdomain of a name.
///
/// - `evil.com` matches **only** `evil.com` (the apex). It does not match `www.evil.com`.
/// - `*.evil.com` matches `www.evil.com` and `a.b.evil.com` (any depth of subdomain) but **not** the apex
///   `evil.com`. To cover both, add both rules.
///
/// Matching is on label boundaries (`notevil.com` matches neither), case-insensitive, and tolerant of one trailing dot
/// on the rule or the host (`Evil.COM.` is `evil.com`). Names must be ASCII; write internationalized names in their
/// `xn--` form. A rule that is really an IP address in some spelling is rejected, since it would never match a name.
///
/// A name rule judges the name the client *asked for*. It cannot see through a CNAME or a different name for the same
/// server; pair it with address rules when that matters. `Codable` encodes the rule text and re-validates on decode.
struct DomainRule: Hashable, Sendable, Codable, CustomStringConvertible {
    enum Scope: Hashable, Sendable {
        /// Only the named host.
        case exact
        /// Strict subdomains of the name, at any depth; excludes the name itself.
        case subdomains
    }

    let scope: Scope
    /// Normalized: lower-case, no trailing dot, no `*.` prefix.
    let name: String

    /// - Throws: ``NetworkPolicyError/empty``, ``NetworkPolicyError/invalidDomain(_:)`` for malformed names or
    ///   wildcards anywhere but a leading `*.`, ``NetworkPolicyError/domainLooksLikeAddress(_:)``.
    init(_ text: String) throws(NetworkPolicyError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let isWildcard = trimmed.hasPrefix("*.")
        let form: HostForm
        do {
            form = try HostForm(parsing: isWildcard ? String(trimmed.dropFirst(2)) : trimmed)
        } catch {
            throw error == .malformed ? .invalidDomain(text) : .domainLooksLikeAddress(text)
        }
        guard case .name(let name) = form else { throw .domainLooksLikeAddress(text) }
        self.scope = isWildcard ? .subdomains : .exact
        self.name = name
    }

    /// Whether the rule covers `hostName`, which must already be normalized (see ``HostForm``).
    func matches(_ hostName: String) -> Bool {
        switch scope {
        case .exact: hostName == name
        case .subdomains: hostName.hasSuffix("." + name)
        }
    }

    var description: String {
        scope == .subdomains ? "*." + name : name
    }

    init(from decoder: any Decoder) throws {
        self = try StringRuleCoding.decode(decoder, kind: "domain rule") { try Self($0) }
    }

    func encode(to encoder: any Encoder) throws {
        try StringRuleCoding.encode(description, to: encoder)
    }
}

/// A plain-HTTP URL prefix: `http://host[:port][/path]`.
///
/// **Enforcement limit.** Only requests a host-side proxy can read in full carry a path: plain `http`. For `https`
/// the proxy sees `CONNECT host:port` and then an opaque TLS stream, so no path, query, or header is visible.
/// This type therefore accepts the `http` scheme only; to restrict an HTTPS site, block its host with a
/// ``DomainRule`` or its addresses with an ``AddressRule``.
///
/// Matching: the host must match (a ``DomainRule``-style name, `*.` wildcards allowed, or an IP literal compared after
/// IPv4-mapped normalization); the port must equal the rule's port when one is given (the URL's default port is 80);
/// and the normalized path (see ``URLPath``) must start with the rule's path **on segment boundaries**, so `/admin`
/// covers `/admin`, `/admin/x`, and `/ADMIN/../admin;v=1`, but not `/administrator`. No path means the whole host.
/// Credentials, query strings, and fragments are rejected in rules. `Codable` encodes the canonical text.
struct URLRule: Hashable, Sendable, Codable, CustomStringConvertible {
    enum Host: Hashable, Sendable {
        case name(DomainRule)
        case address(IPAddress)
    }

    let host: Host
    /// `nil` matches any port.
    let port: UInt16?
    /// Normalized path segments; empty means every path.
    let pathSegments: [String]

    /// - Throws: ``NetworkPolicyError/empty``, ``NetworkPolicyError/invalidURL(_:)``,
    ///   ``NetworkPolicyError/unsupportedScheme(_:)`` for anything but `http`,
    ///   ``NetworkPolicyError/unsupportedURLComponent(_:)`` for userinfo, query, or fragment, and the domain errors
    ///   for the host.
    init(_ text: String) throws(NetworkPolicyError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard let separator = trimmed.range(of: "://") else { throw .invalidURL(text) }
        let scheme = trimmed[..<separator.lowerBound].lowercased()
        guard !scheme.isEmpty else { throw .invalidURL(text) }
        guard scheme == "http" else { throw .unsupportedScheme(scheme) }
        let rest = trimmed[separator.upperBound...]
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let authority = String(rest[..<authorityEnd])
        let pathText = String(rest[authorityEnd...])
        guard !authority.contains("@") else { throw .unsupportedURLComponent("credentials") }
        guard !pathText.contains("?"), !pathText.contains("#") else { throw .unsupportedURLComponent("a query or fragment") }
        guard let segments = URLPath.normalizedSegments(pathText) else { throw .invalidURL(text) }
        let (hostText, port) = try Self.split(authority: authority, original: text)
        self.host = try Self.parseHost(hostText, original: text)
        self.port = port
        self.pathSegments = segments
    }

    private static func split(authority: String, original: String) throws(NetworkPolicyError) -> (String, UInt16?) {
        var hostText = Substring(authority)
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw .invalidURL(original) }
            hostText = authority[...close]
            let tail = authority[authority.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { throw .invalidURL(original) }
                portText = tail.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: ":") {
            hostText = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        }
        guard let portText else { return (String(hostText), nil) }
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let port = UInt16(portText), port != 0
        else { throw .invalidURL(original) }
        return (String(hostText), port)
    }

    private static func parseHost(_ text: String, original: String) throws(NetworkPolicyError) -> Host {
        if text.hasPrefix("*.") { return .name(try DomainRule(text)) }
        let form: HostForm
        do {
            form = try HostForm(parsing: text)
        } catch {
            throw .invalidURL(original)
        }
        switch form {
        case .address(let address): return .address(address.normalized)
        case .name: return .name(try DomainRule(text))
        }
    }

    /// Whether a request to `target` on `targetPort` with the already-normalized `targetPath` falls under this rule.
    func matches(host target: HostForm, port targetPort: UInt16, pathSegments targetPath: [String]) -> Bool {
        guard hostMatches(target) else { return false }
        if let port, port != targetPort { return false }
        return targetPath.starts(with: pathSegments)
    }

    private func hostMatches(_ target: HostForm) -> Bool {
        switch (host, target) {
        case (.name(let rule), .name(let name)): rule.matches(name)
        case (.address(let ruleAddress), .address(let address)): ruleAddress.normalized == address.normalized
        default: false
        }
    }

    var description: String {
        var text = "http://"
        switch host {
        case .name(let rule): text += rule.description
        case .address(let address):
            if case .v6 = address { text += "[\(address)]" } else { text += address.description }
        }
        if let port { text += ":\(port)" }
        return text + "/" + pathSegments.map(URLPath.encode).joined(separator: "/")
    }

    init(from decoder: any Decoder) throws {
        self = try StringRuleCoding.decode(decoder, kind: "URL rule") { try Self($0) }
    }

    func encode(to encoder: any Encoder) throws {
        try StringRuleCoding.encode(description, to: encoder)
    }
}
