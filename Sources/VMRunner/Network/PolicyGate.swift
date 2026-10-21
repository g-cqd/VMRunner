import Foundation

/// IP-to-name memory of what the DNS proxy told the guest, so a later connection to a bare address can be judged
/// by the names that led the guest there.
///
/// Bounded: at most `capacity` addresses and `namesPerAddress` names each; expired entries go first, then the
/// entry that expires soonest. An address that several names share (a CDN) keeps all of them.
struct NameTable {
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
    mutating func record(name: String, address: UInt32, ttl: TimeInterval, now: TimeInterval) {
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

    mutating func prune(now: TimeInterval) {
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
enum GateVerdict: Hashable, Sendable {
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
struct PolicyGate {
    var policy: NetworkPolicy
    var names = NameTable()

    init(policy: NetworkPolicy) {
        self.policy = policy
    }

    /// Judges a connection to `address:port`. Allocates (strings and arrays): called once per new flow, never per packet.
    func judge(address: UInt32, port: UInt16, now: TimeInterval) -> GateVerdict {
        let ip = IPAddress.v4(address)
        let literal = policy.evaluate(host: ip.description, port: port, resolvedAddresses: [])
        let known = names.names(for: address, now: now)
        if case .deny(let reason) = literal, Self.isBlock(reason) { return .deny(reason, name: known.last) }
        var allowedName: String?
        var softDenial: NetworkPolicy.Reason?
        for name in known.reversed() {
            switch policy.evaluate(host: name, port: port, resolvedAddresses: [ip]) {
            case .allow: allowedName = allowedName ?? name
            case .deny(let reason):
                if Self.isBlock(reason) { return .deny(reason, name: name) }
                softDenial = softDenial ?? reason
            }
        }
        if literal == .allow { return .allow(name: allowedName ?? known.last) }
        if let allowedName { return .allow(name: allowedName) }
        if case .deny(let reason) = literal { return .deny(softDenial ?? reason, name: known.last) }
        return .allow(name: known.last)
    }

    /// Judges an ICMP echo: like a connection with no port, so a port allow-list does not apply.
    func judgeEcho(address: UInt32, now: TimeInterval) -> GateVerdict {
        let verdict = judge(address: address, port: 0, now: now)
        if case .deny(.portNotAllowListed, let name) = verdict { return .allow(name: name) }
        return verdict
    }

    /// Whether the guest may resolve `name` at all: only definite refusals (a blocked domain, or a connection
    /// rule that blocks the name on every port) deny here. Everything else is decided per connection.
    func nameBlock(for name: String) -> NetworkPolicy.Reason? {
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
