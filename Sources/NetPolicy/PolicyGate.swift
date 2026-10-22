package import Foundation

/// IP-to-name memory of what the DNS proxy told the guest, so a later connection to a bare address can be judged
/// by the names that led the guest there.
///
/// Bounded: at most `capacity` addresses and `namesPerAddress` names each; expired entries go first, then the
/// entry that expires soonest. An address that several names share (a CDN) keeps all of them.
package struct NameTable {
    private struct Entry {
        var name: String
        var expires: TimeInterval
    }

    private var entries: [UInt32: [Entry]] = [:]
    private let capacity: Int
    private let namesPerAddress = 4

    init(capacity: Int = 4_096) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    var count: Int { entries.count }

    /// Remembers that `name` resolved to `address` for `ttl` seconds.
    package mutating func record(name: String, address: UInt32, ttl: TimeInterval, now: TimeInterval) {
        if entries[address] == nil, entries.count >= capacity { evict(now: now) }
        var list = (entries[address] ?? []).filter { $0.expires > now && $0.name != name }
        list.append(Entry(name: name, expires: now + ttl))
        if list.count > namesPerAddress { list.removeFirst(list.count - namesPerAddress) }
        entries[address] = list
    }

    /// The unexpired names for `address`, most recent last.
    func names(for address: UInt32, now: TimeInterval) -> [String] {
        (entries[address] ?? []).filter { $0.expires > now }.map(\.name)
    }

    package mutating func prune(now: TimeInterval) {
        entries = entries.filter { $0.value.contains { $0.expires > now } }
    }

    private mutating func evict(now: TimeInterval) {
        prune(now: now)
        guard entries.count >= capacity else { return }
        let soonest = entries.min { lhs, rhs in
            (lhs.value.map(\.expires).max() ?? 0) < (rhs.value.map(\.expires).max() ?? 0)
        }
        if let soonest { entries[soonest.key] = nil }
    }
}

/// The verdict on one connection attempt.
package enum GateVerdict: Hashable, Sendable {
    /// Allowed; `name` is the DNS name the guest was given for this address, if any.
    case allow(name: String?)
    case deny(NetworkPolicy.Reason, name: String?)
}

/// Applies ``NetworkPolicy`` to guest traffic, using the DNS proxy's IP-to-name memory.
///
/// ## How a connection is judged
/// The destination address is evaluated as a literal (`evaluate(host: "93.184.216.34", ...)`), so address, port,
/// connection and private-range rules apply. If the DNS proxy previously gave the guest this address for one or more
/// names, each name is evaluated as well, with the address as its resolution, so domain and connection rules apply
/// too.
/// - **Deny beats allow**: any *block* verdict on the literal or on any known name denies.
/// - **Allow needs one yes**: if nothing blocks, the connection is allowed when the literal or any known name is
///   allowed (allow-list mode: `allowedDomains` can allow an address the guest reached through an allowed name).
///
/// Names are advisory (a guest can connect to an address it learned elsewhere, and a shared address inherits every
/// name that pointed at it), addresses are authoritative: the host connection is always made to the very address
/// that was judged.
package struct PolicyGate {
    package var policy: NetworkPolicy
    package var names = NameTable()
    /// Floor ranges not enforced; always empty outside the integration tests (see `UserNetConfig.exemptedFloorKinds`).
    let floorExemptions: Set<ReservedRangeKind>

    package init(policy: NetworkPolicy, floorExemptions: Set<ReservedRangeKind> = []) {
        self.policy = policy
        self.floorExemptions = floorExemptions
    }

    private func evaluate(_ host: String, port: UInt16, resolvedAddresses: [IPAddress]) -> NetworkPolicy.Decision {
        policy.evaluate(host: host, port: port, resolvedAddresses: resolvedAddresses, exempting: floorExemptions)
    }

    /// Judges a connection to `address:port`. Allocates (strings and arrays): called once per new flow, never per packet.
    package func judge(address: UInt32, port: UInt16, now: TimeInterval) -> GateVerdict {
        let ip = IPAddress.v4(address)
        let literal = evaluate(ip.description, port: port, resolvedAddresses: [])
        let known = names.names(for: address, now: now)
        if case .deny(let reason) = literal, Self.isBlock(reason) { return .deny(reason, name: known.last) }
        var allowedName: String?
        var softDenial: NetworkPolicy.Reason?
        for name in known.reversed() {
            switch evaluate(name, port: port, resolvedAddresses: [ip]) {
            case .allow: allowedName = allowedName ?? name
            case .deny(let reason):
                if Self.isBlock(reason) { return .deny(reason, name: name) }
                softDenial = softDenial ?? reason
            }
        }
        switch literal {
        case .allow:
            return .allow(name: allowedName ?? known.last)
        case .deny(let reason):
            if let allowedName { return .allow(name: allowedName) }
            return .deny(softDenial ?? reason, name: known.last)
        }
    }

    /// Judges an ICMP echo: like a connection with no port, so a port allow-list does not apply.
    package func judgeEcho(address: UInt32, now: TimeInterval) -> GateVerdict {
        let verdict = judge(address: address, port: 0, now: now)
        if case .deny(.portNotAllowListed, let name) = verdict { return .allow(name: name) }
        return verdict
    }

    /// Whether the DNS proxy may ask the host resolver for `name` on the guest's behalf. Resolving is a policy
    /// decision, because the host's resolver reaches things the guest cannot (split-DNS and VPN zones, `.local`, the
    /// local network): the answer is a refusal when
    /// - ``nameBlock(for:)`` refuses the name;
    /// - the name is `.local` or `.arpa`, other than the reverse lookup of an IPv4 address (`d.c.b.a.in-addr.arpa`), which is
    ///   judged as that address, as for a ping;
    /// - in allow-list mode, no allowed domain or connection rule names it.
    package func resolutionDenial(for name: String, now: TimeInterval) -> NetworkPolicy.Reason? {
        if let reason = nameBlock(for: name) { return reason }
        guard let form = try? HostForm(parsing: name), case .name(let normalized) = form else { return nil }
        if let address = Self.reversedAddress(normalized) {
            if case .deny(let reason, _) = judgeEcho(address: address, now: now) { return reason }
            return nil
        }
        if ["local", "arpa"].contains(where: { normalized == $0 || normalized.hasSuffix("." + $0) }) { return .reservedName }
        if policy.mode == .allowListed, !allowsResolving(normalized) { return .notAllowListed }
        return nil
    }

    /// A refusal of `address` as an answer for `name` that holds on every port: a built-in range, a blocked address or
    /// a connection rule that blocks all ports. What depends on the port or on the allow-list is left to the
    /// connection, which is judged when the guest makes it.
    package func addressBlock(_ address: UInt32, for name: String) -> NetworkPolicy.Reason? {
        guard case .deny(let reason) = evaluate(name, port: 0, resolvedAddresses: [.v4(address)]), Self.isBlock(reason)
        else { return nil }
        return reason
    }

    /// Whether an allow rule names `name`: an allowed domain, or an allowed connection whose target is a domain.
    private func allowsResolving(_ name: String) -> Bool {
        if policy.allowedDomains.contains(where: { $0.matches(name) }) { return true }
        return policy.allowedConnections.contains { rule in
            if case .name(let domain) = rule.target { domain.matches(name) } else { false }
        }
    }

    /// The address a name under `in-addr.arpa` asks about, for exactly four canonical decimal labels.
    private static func reversedAddress(_ name: String) -> UInt32? {
        let suffix = ".in-addr.arpa"
        guard name.hasSuffix(suffix) else { return nil }
        let octets = name.dropLast(suffix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var address: UInt32 = 0
        for label in octets.reversed() {
            guard label.utf8.count <= 3, label.utf8.allSatisfy({ (0x30...0x39).contains($0) }), label.count == 1 || label.first != "0",
                let value = UInt8(label)
            else { return nil }
            address = address << 8 | UInt32(value)
        }
        return address
    }

    /// The definite refusals of a name: a blocked domain, or a connection rule that blocks the name on every port.
    /// Alone, it is what the names on a CNAME chain are held to (an allow-list does not apply to a CDN's name);
    /// everything else is decided per connection.
    package func nameBlock(for name: String) -> NetworkPolicy.Reason? {
        guard let form = try? HostForm(parsing: name) else { return .malformedHost }
        guard case .name(let normalized) = form else { return nil }
        if let rule = policy.blockedDomains.first(where: { $0.matches(normalized) }) { return .blockedDomain(rule) }
        for rule in policy.blockedConnections where rule.ports.isEmpty {
            if case .name(let domain) = rule.target, domain.matches(normalized) { return .blockedConnection(rule) }
        }
        return nil
    }

    private static func isBlock(_ reason: NetworkPolicy.Reason) -> Bool {
        switch reason {
        case .notAllowListed, .portNotAllowListed, .urlNotAllowListed, .unresolved: false
        default: true
        }
    }
}
