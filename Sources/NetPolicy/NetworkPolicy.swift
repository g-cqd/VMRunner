import Foundation

/// Egress rules for one guest, as a pure value with a pure evaluator.
///
/// ## What this can and cannot enforce
/// Virtualization.framework NAT networking has no filter of its own, and bridged/vmnet need restricted entitlements.
/// The host can therefore only (a) toggle the guest NIC attachment as a kill switch, or (b) remove the NIC and have
/// the guest reach the world through a host-side proxy over vsock. This type is the decision function for (b).
/// What a proxy can see decides what a rule can do:
/// - **HTTPS and any CONNECT tunnel**: only `host:port` (and the addresses it resolves to). URL paths, queries, and
///   headers are inside TLS and are never visible. ``evaluate(url:resolvedAddresses:)`` reports this with
///   ``URLEvaluation/pathRulesApplied`` `== false`; ``blockedURLPrefixes`` do **not** apply to https.
/// - **Plain HTTP**: the full request line, so URL prefix rules apply.
/// - **Anything not routed through the proxy** (a guest that finds another path out) is not covered at all.
/// - **Names are advisory, addresses are authoritative**: a client can send an allowed `Host`/SNI over a connection
///   to a forbidden address. Always connect to the very addresses you evaluated (pin them); re-resolving after the
///   check reopens the DNS-rebinding window this evaluator closes.
///
/// ## Evaluation order (first match wins; deny beats allow)
/// 1. the host must parse (see ``HostForm``): malformed hosts and non-canonical numeric spellings are denied;
/// 2. ``blockedPorts``;
/// 3. ``blockedDomains`` (names only);
/// 4. a name with no resolved addresses is denied (`.unresolved`): it cannot be connected to safely;
/// 5. **every** address (the literal itself plus all `resolvedAddresses`) against the built-in ranges and
///    ``blockedAddresses``, including the IPv4 address embedded in mapped, NAT64, 6to4, and IPv4-compatible IPv6
///    forms. The built-in ranges are the *floor* (loopback, unspecified, link-local and cloud metadata, the NAT
///    gateway and `198.18.0.0/15`: see ``ReservedRangeKind/isFloor``), always denied, and the private networks
///    (RFC 1918, carrier-grade NAT, unique-local, multicast and the reserved blocks), denied while
///    ``blockPrivateRanges`` is on;
/// 6. in ``Mode/allowListed``, the host must match ``allowedDomains``, or every address must lie in
///    ``allowedAddresses``; otherwise `.notAllowListed`;
/// 7. for http URLs, ``blockedURLPrefixes``.
///
/// Allow-list entries never override a block: allowing `127.0.0.1` or `192.168.64.1` still denies, because those are
/// the floor, and allowing `10.0.0.5` denies while ``blockPrivateRanges`` is on. Turn ``blockPrivateRanges`` off to
/// allow a private network deliberately; nothing lifts the floor.
///
/// The VPN requirement is not part of `evaluate`; it depends on host state over time, not on a destination.
package struct NetworkPolicy: Hashable, Sendable, Codable {
    package enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
        /// Everything is allowed except what a rule blocks.
        case denyListed
        /// Only ``NetworkPolicy/allowedDomains`` / ``NetworkPolicy/allowedAddresses`` are allowed, minus blocks.
        case allowListed
    }

    /// Why a destination was denied.
    package enum Reason: Hashable, Sendable {
        case malformedHost
        /// A numeric host that is not canonical dotted-quad (`2130706433`, `0x7f000001`, `0177.0.0.1`, `127.1`).
        case nonCanonicalAddress
        case malformedURL
        case unsupportedScheme(String)
        case blockedPort(UInt16)
        case blockedConnection(ConnectionRule)
        /// Allow-list mode: the destination is allowed but not on this port.
        case portNotAllowListed(UInt16)
        /// Allow-list mode: no allowed URL prefix matches this http URL.
        case urlNotAllowListed
        /// `address` (as resolved or written) lies in a built-in non-public range.
        case reservedRange(ReservedRangeKind, address: IPAddress)
        case blockedAddress(AddressRule, address: IPAddress)
        case blockedDomain(DomainRule)
        case blockedURL(URLRule)
        /// Allow-list mode and nothing allowed this destination.
        case notAllowListed
        /// A name arrived without resolved addresses.
        case unresolved
        /// The DNS proxy does not resolve this name for a guest: `.local` (the host would ask the local network) and
        /// `.arpa` names other than the reverse lookup of an address.
        case reservedName
    }

    package enum Decision: Hashable, Sendable {
        case allow
        case deny(Reason)

        package var isAllowed: Bool { self == .allow }
    }

    /// The verdict for a URL, plus whether path rules were part of it.
    struct URLEvaluation: Hashable, Sendable {
        let decision: Decision
        /// `true` for http URLs: ``NetworkPolicy/blockedURLPrefixes`` were consulted. `false` for https (path invisible
        /// to a proxy: only host, port, and addresses were judged) and for URLs that failed to parse.
        let pathRulesApplied: Bool
    }

    /// Longest rule, in the canonical text a policy stores it as. A URL prefix is the longest kind.
    package static let maxRuleLength = 2048

    /// Block the private networks: RFC 1918, carrier-grade NAT (`100.64.0.0/10`), unique-local IPv6, multicast and the
    /// reserved blocks. On by default. It does not govern the *floor* (loopback, `0.0.0.0`, link-local and cloud
    /// metadata, the NAT gateway `192.168.64.0/24`, `198.18.0.0/15`): those are denied whatever this says.
    package var blockPrivateRanges = true
    var blockedAddresses: [AddressRule] = []
    package var blockedDomains: [DomainRule] = []
    /// Enforced for http only; see the type documentation.
    var blockedURLPrefixes: [URLRule] = []
    var blockedPorts: [PortRule] = []
    /// A destination plus ports, denied: `ssh to this block` without blocking the block entirely.
    package var blockedConnections: [ConnectionRule] = []
    package var mode = Mode.denyListed
    package var allowedDomains: [DomainRule] = []
    package var allowedAddresses: [AddressRule] = []
    /// In allow-list mode, when not empty, an allowed destination must also use one of these ports.
    var allowedPorts: [PortRule] = []
    /// In allow-list mode, a destination plus ports that is allowed on its own: "only HTTPS to GitHub".
    package var allowedConnections: [ConnectionRule] = []
    /// In allow-list mode, when not empty, an http URL must also start with one of these (https paths are invisible).
    var allowedURLPrefixes: [URLRule] = []
    package var vpn = VPNRequirement.ignore

    package init() {}

    private enum CodingKeys: String, CodingKey {
        case blockPrivateRanges, blockedAddresses, blockedDomains, blockedURLPrefixes, blockedPorts, blockedConnections
        case mode, allowedDomains, allowedAddresses, allowedPorts, allowedConnections, allowedURLPrefixes, vpn
    }

    /// Missing keys take their defaults, so policies saved by older versions keep decoding.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockPrivateRanges = try container.decodeIfPresent(Bool.self, forKey: .blockPrivateRanges) ?? true
        blockedAddresses = try container.decodeIfPresent([AddressRule].self, forKey: .blockedAddresses) ?? []
        blockedDomains = try container.decodeIfPresent([DomainRule].self, forKey: .blockedDomains) ?? []
        blockedURLPrefixes = try container.decodeIfPresent([URLRule].self, forKey: .blockedURLPrefixes) ?? []
        blockedPorts = try container.decodeIfPresent([PortRule].self, forKey: .blockedPorts) ?? []
        blockedConnections = try container.decodeIfPresent([ConnectionRule].self, forKey: .blockedConnections) ?? []
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .denyListed
        allowedDomains = try container.decodeIfPresent([DomainRule].self, forKey: .allowedDomains) ?? []
        allowedAddresses = try container.decodeIfPresent([AddressRule].self, forKey: .allowedAddresses) ?? []
        allowedPorts = try container.decodeIfPresent([PortRule].self, forKey: .allowedPorts) ?? []
        allowedConnections = try container.decodeIfPresent([ConnectionRule].self, forKey: .allowedConnections) ?? []
        allowedURLPrefixes = try container.decodeIfPresent([URLRule].self, forKey: .allowedURLPrefixes) ?? []
        vpn = try container.decodeIfPresent(VPNRequirement.self, forKey: .vpn) ?? .ignore
    }

    // MARK: Evaluation

    /// Decides whether a connection to `host:port` may proceed.
    ///
    /// - Parameters:
    ///   - host: A DNS name or IP literal as the client wrote it (brackets and one trailing dot tolerated).
    ///   - port: The destination port.
    ///   - resolvedAddresses: Every address the name resolved to, as returned by the resolver (IPv4-mapped forms are
    ///     fine). All must pass. For a literal IP host the literal itself is checked too.
    /// - Returns: `.allow`, or `.deny` with the first reason found. Never throws; unparseable input is a denial.
    /// - Note: connect only to addresses you passed here.
    package func evaluate(host: String, port: UInt16, resolvedAddresses: [IPAddress]) -> Decision {
        evaluate(host: host, port: port, resolvedAddresses: resolvedAddresses, exempting: [])
    }

    /// As ``evaluate(host:port:resolvedAddresses:)``, with `floorKinds` not enforced. For the integration tests, which
    /// must reach servers they start on the loopback interface: nothing outside the tests passes a non-empty set
    /// (`UserNetConfig.exemptedFloorKinds` is the only source), and the policy itself has no such setting.
    package func evaluate(host: String, port: UInt16, resolvedAddresses: [IPAddress], exempting floorKinds: Set<ReservedRangeKind>)
        -> Decision
    {
        let form: HostForm
        do {
            form = try HostForm(parsing: host)
        } catch {
            return .deny(error.reason)
        }
        return evaluate(form: form, port: port, resolvedAddresses: resolvedAddresses, exempting: floorKinds)
    }

    /// Decides whether a request for `url` may proceed.
    ///
    /// The URL is normalized before any rule sees it: scheme and host are case-insensitive; credentials
    /// (`http://good.com@evil.com/`) are ignored, so the host is the one actually connected to (`evil.com`), and a
    /// backslash in them is denied as a parser-confusion attempt; the port defaults to 80 or 443; the path is
    /// decoded, `..`-resolved, and lower-cased (see ``URLPath``). Only `http` and `https` are accepted.
    ///
    /// - Parameters:
    ///   - url: The absolute URL, parsed with the same parser the proxy will use to connect.
    ///   - resolvedAddresses: As for ``evaluate(host:port:resolvedAddresses:)``.
    /// - Returns: The decision and whether path rules were applicable. For https the path is not judged.
    func evaluate(url: URL, resolvedAddresses: [IPAddress]) -> URLEvaluation {
        let target: NormalizedURL
        do {
            target = try NormalizedURL(url)
        } catch {
            return URLEvaluation(decision: .deny(error.reason), pathRulesApplied: false)
        }
        let decision = evaluate(form: target.host, port: target.port, resolvedAddresses: resolvedAddresses, exempting: [])
        let pathRulesApply = target.scheme == .http
        guard decision.isAllowed, pathRulesApply else { return URLEvaluation(decision: decision, pathRulesApplied: pathRulesApply) }
        func matches(_ rule: URLRule) -> Bool {
            rule.matches(host: target.host, port: target.port, pathSegments: target.segments)
        }
        if let blocking = blockedURLPrefixes.first(where: matches) {
            return URLEvaluation(decision: .deny(.blockedURL(blocking)), pathRulesApplied: true)
        }
        let outsideAllowedURLs = mode == .allowListed && !allowedURLPrefixes.isEmpty && !allowedURLPrefixes.contains(where: matches)
        return URLEvaluation(decision: outsideAllowedURLs ? .deny(.urlNotAllowListed) : .allow, pathRulesApplied: true)
    }

    private func evaluate(form: HostForm, port: UInt16, resolvedAddresses: [IPAddress], exempting floorKinds: Set<ReservedRangeKind>)
        -> Decision
    {
        if blockedPorts.contains(where: { $0.contains(port) }) { return .deny(.blockedPort(port)) }
        var addresses = resolvedAddresses
        switch form {
        case .address(let literal):
            addresses.insert(literal, at: 0)
        case .name(let name):
            if let rule = blockedDomains.first(where: { $0.matches(name) }) { return .deny(.blockedDomain(rule)) }
            if resolvedAddresses.isEmpty { return .deny(.unresolved) }
        }
        if let rule = blockedConnections.first(where: { $0.blocks(host: form, port: port, addresses: addresses) }) {
            return .deny(.blockedConnection(rule))
        }
        if let reason = firstAddressDenial(in: addresses, exempting: floorKinds) { return .deny(reason) }
        guard mode == .allowListed else { return .allow }
        return allowListDecision(form, port: port, addresses: addresses)
    }

    /// Allow-list mode, after every block has passed: an allowed connection rule is enough on its own; otherwise the
    /// destination must be allow-listed and, if ports are listed, so must the port.
    private func allowListDecision(_ form: HostForm, port: UInt16, addresses: [IPAddress]) -> Decision {
        if allowedConnections.contains(where: { $0.allows(host: form, port: port, addresses: addresses) }) { return .allow }
        guard isAllowListed(form, addresses: addresses) else { return .deny(.notAllowListed) }
        if !allowedPorts.isEmpty, !allowedPorts.contains(where: { $0.contains(port) }) { return .deny(.portNotAllowListed(port)) }
        return .allow
    }

    private func firstAddressDenial(in addresses: [IPAddress], exempting floorKinds: Set<ReservedRangeKind>) -> Reason? {
        for address in addresses {
            for candidate in address.blockCandidates {
                if let kind = ReservedRanges.enforcedKind(of: candidate, blockingPrivateRanges: blockPrivateRanges, exempting: floorKinds) {
                    return .reservedRange(kind, address: address)
                }
                if let rule = blockedAddresses.first(where: { $0.contains(candidate) }) {
                    return .blockedAddress(rule, address: address)
                }
            }
        }
        return nil
    }

    private func isAllowListed(_ form: HostForm, addresses: [IPAddress]) -> Bool {
        if case .name(let name) = form, allowedDomains.contains(where: { $0.matches(name) }) { return true }
        return !addresses.isEmpty
            && addresses.allSatisfy { address in allowedAddresses.contains { $0.contains(address.normalized) } }
    }
}

extension HostForm.ParseError {
    fileprivate var reason: NetworkPolicy.Reason {
        switch self {
        case .malformed: .malformedHost
        case .nonCanonicalAddress: .nonCanonicalAddress
        }
    }
}

/// The parts of a URL the policy judges, after normalization.
private struct NormalizedURL {
    enum Scheme { case http, https }

    enum Failure: Error {
        case malformed
        case unsupportedScheme(String)
        case host(HostForm.ParseError)

        var reason: NetworkPolicy.Reason {
            switch self {
            case .malformed: .malformedURL
            case .unsupportedScheme(let scheme): .unsupportedScheme(scheme)
            case .host(let error): error.reason
            }
        }
    }

    let scheme: Scheme
    let host: HostForm
    let port: UInt16
    let segments: [String]

    init(_ url: URL) throws(Failure) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let rawScheme = parts.scheme?.lowercased()
        else { throw .malformed }
        switch rawScheme {
        case "http": scheme = .http
        case "https": scheme = .https
        default: throw .unsupportedScheme(rawScheme)
        }
        let credentials = ((parts.percentEncodedUser ?? "") + (parts.percentEncodedPassword ?? "")).lowercased()
        guard !credentials.contains("\\"), !credentials.contains("%5c") else { throw .malformed }
        guard let hostText = parts.percentEncodedHost, !hostText.isEmpty else { throw .malformed }
        do {
            host = try HostForm(parsing: hostText)
        } catch {
            throw .host(error)
        }
        if let explicit = parts.port {
            guard let valid = UInt16(exactly: explicit), valid != 0 else { throw .malformed }
            port = valid
        } else {
            port = scheme == .http ? 80 : 443
        }
        guard let normalized = URLPath.normalizedSegments(parts.percentEncodedPath) else { throw .malformed }
        segments = normalized
    }
}
