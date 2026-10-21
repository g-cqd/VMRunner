import Foundation

/// How a DNS answer travels back to the guest.
enum DNSReplyRoute: Hashable {
    /// UDP from `server` port 53 to the guest's `guestPort`.
    case udp(guestPort: UInt16, server: UInt32)
    /// Length-prefixed on the TCP flow with this token.
    case tcp(flowToken: UInt64)
}

/// A finished DNS exchange, ready to send and to report.
struct DNSAnswer {
    let route: DNSReplyRoute
    let message: [UInt8]
    let name: String
    let responseCode: UInt8
    /// Set when the policy refused the name.
    let denial: NetworkPolicy.Reason?
    let server: UInt32
}

/// What happened to a query handed to the proxy.
enum DNSBeginOutcome {
    /// Answered without resolving (refused, malformed, AAAA, or too many in flight).
    case answered(DNSAnswer)
    /// Resolution started on this token; ``DNSProxy/complete(token:result:gate:now:)`` finishes it.
    case pending(token: UInt64, name: String, type: UInt16)
    /// Not a query this proxy can answer; nothing is sent.
    case ignored
}

/// The DNS server the guest talks to, in front of the host's resolver.
///
/// - **Resolution** goes to the host (``HostNameResolver``), so split-DNS and VPN DNS configured on the Mac apply.
///   That makes resolving a policy decision, not a service: the guest chooses the names, and the host's resolver
///   reaches more than the guest could.
/// - **What is asked**: only A, AAAA, CNAME and PTR questions are answered (anything else is NOTIMP, never forwarded).
///   Before resolving, ``PolicyGate/resolutionDenial(for:now:)`` refuses a blocked name, `.local`, `.arpa` other than
///   the reverse lookup of an address the policy allows, and, in allow-list mode, any name no rule allows; the guest
///   gets the configured block response and nothing reaches the resolver. The same check runs again when the answer
///   arrives, because the policy may have changed meanwhile.
/// - **What is answered**: the records are rebuilt from what is valid, not echoed. Only the CNAME chain that starts at
///   the queried name and the final name's records are kept (a record for any other owner is dropped), CNAME and PTR
///   data must be a well-formed name, and every CNAME target is held to the block rules. An address the policy refuses
///   on every port (built-in ranges, blocked addresses) is removed; when that leaves a question with no address, the
///   guest gets the block response.
/// - **Memory**: every address in the answer is remembered with the names of that chain in the gate's ``NameTable``.
/// - **IPv6**: the guest has no IPv6, so AAAA questions get an empty NOERROR answer (after the policy check) and
///   guests use IPv4 without waiting for a timeout.
final class DNSProxy {
    private struct Pending {
        let query: DNSQuery
        let route: DNSReplyRoute
        let server: UInt32
        let deadline: TimeInterval
    }

    /// The record types a guest needs from a stub resolver; every other type is answered NOTIMP.
    private static let answeredTypes: Set<UInt16> = [DNSCode.typeA, DNSCode.typeAAAA, DNSCode.typeCNAME, DNSCode.typePTR]
    private static let maximumPending = 256
    /// CNAME links followed from the queried name.
    private static let maximumChain = 8
    /// Addresses kept per answer, so one answer cannot flush the name table.
    private static let maximumAddresses = 32
    private static let minimumTTL: UInt32 = 30
    private static let maximumTTL: UInt32 = 3_600

    private var pending: [UInt64: Pending] = [:]

    var pendingCount: Int { pending.count }

    /// Starts handling one query message from the guest.
    func begin(
        _ message: ByteView, route: DNSReplyRoute, server: UInt32, gate: PolicyGate, ctx: UserNetContext<some UserNetHost>
    ) -> DNSBeginOutcome {
        let query: DNSQuery
        do {
            query = try DNSWire.parseQuery(message)
        } catch {
            return .ignored
        }
        ctx.stats.dnsQueries += 1
        func answer(_ code: UInt8, denial: NetworkPolicy.Reason? = nil, records: [DNSRecord] = []) -> DNSBeginOutcome {
            .answered(
                DNSAnswer(
                    route: route, message: DNSWire.response(to: query, code: code, records: records, truncateOverUDP: route.isUDP),
                    name: query.name, responseCode: code, denial: denial, server: server))
        }
        guard query.opcode == 0 else { return answer(DNSCode.notImplemented) }
        guard query.queryClass == DNSCode.classIN else { return answer(DNSCode.refused) }
        guard Self.answeredTypes.contains(query.type) else { return answer(DNSCode.notImplemented) }
        if let reason = gate.resolutionDenial(for: query.name, now: ctx.now) {
            ctx.stats.dnsBlocked += 1
            return answer(blockCode(ctx.config), denial: reason)
        }
        if query.type == DNSCode.typeAAAA { return answer(DNSCode.noError) }
        guard pending.count < Self.maximumPending else { return answer(DNSCode.serverFailure) }
        let token = ctx.makeToken()
        pending[token] = Pending(query: query, route: route, server: server, deadline: ctx.now + ctx.config.dnsTimeout)
        return .pending(token: token, name: query.name, type: query.type)
    }

    /// Finishes a query once the host resolver answered. `nil` if the query already timed out.
    func complete(
        token: UInt64, result: DNSLookupResult, gate: inout PolicyGate, ctx: UserNetContext<some UserNetHost>
    ) -> DNSAnswer? {
        guard let entry = pending.removeValue(forKey: token) else { return nil }
        let query = entry.query
        func answer(_ code: UInt8, denial: NetworkPolicy.Reason? = nil, records: [DNSRecord] = []) -> DNSAnswer {
            DNSAnswer(
                route: entry.route,
                message: DNSWire.response(to: query, code: code, records: records, truncateOverUDP: entry.route.isUDP),
                name: query.name, responseCode: code, denial: denial, server: entry.server)
        }
        func blocked(_ reason: NetworkPolicy.Reason) -> DNSAnswer {
            ctx.stats.dnsBlocked += 1
            return answer(blockCode(ctx.config), denial: reason)
        }
        // The policy may have changed while the resolver worked.
        if let reason = gate.resolutionDenial(for: query.name, now: ctx.now) { return blocked(reason) }
        guard result.responseCode == DNSCode.noError else { return answer(result.responseCode) }
        let vetted = vet(result.records, for: query, gate: gate)
        if let reason = vetted.blocked { return blocked(reason) }
        if query.type == DNSCode.typeA, vetted.addressesKept == 0, let reason = vetted.stripped { return blocked(reason) }
        // The resolver said there was an answer and none of it is usable.
        if !result.records.isEmpty, vetted.records.isEmpty { return answer(DNSCode.serverFailure) }
        remember(vetted, gate: &gate, now: ctx.now)
        return answer(DNSCode.noError, records: vetted.records)
    }

    /// Answers every query older than its deadline with SERVFAIL.
    func expire(now: TimeInterval) -> [DNSAnswer] {
        let late = pending.filter { $0.value.deadline <= now }
        guard !late.isEmpty else { return [] }
        return late.map { token, entry in
            pending[token] = nil
            return DNSAnswer(
                route: entry.route, message: DNSWire.response(to: entry.query, code: DNSCode.serverFailure),
                name: entry.query.name, responseCode: DNSCode.serverFailure, denial: nil, server: entry.server)
        }
    }

    private func blockCode(_ config: UserNetConfig) -> UInt8 {
        config.dnsBlockResponse == .refused ? DNSCode.refused : DNSCode.nameError
    }

    /// What survives of a resolver's records, rebuilt to be safe to hand to the guest.
    private struct Vetted {
        /// The CNAME chain, then the records of its last name.
        var records: [DNSRecord] = []
        /// The queried name and every CNAME target followed from it.
        var chain: [String]
        /// Set when a CNAME target is blocked by name.
        var blocked: NetworkPolicy.Reason?
        /// The first reason an address was removed, if any was.
        var stripped: NetworkPolicy.Reason?
        var addressesKept = 0
    }

    /// Follows the CNAME chain from the queried name and keeps what belongs to it. Records for any other owner,
    /// types the question did not ask for, and data that is not valid for its type are left out.
    private func vet(_ records: [DNSRecord], for query: DNSQuery, gate: PolicyGate) -> Vetted {
        var vetted = Vetted(chain: [query.name])
        var current = query.name
        while vetted.chain.count <= Self.maximumChain,
            let link = records.first(where: { $0.type == DNSCode.typeCNAME && $0.name == current }),
            let target = DNSWire.decodeName(link.data), !target.isEmpty, !vetted.chain.contains(target),
            let data = DNSWire.encodeName(target)
        {
            if let reason = gate.nameBlock(for: target) {
                vetted.blocked = reason
                return vetted
            }
            vetted.records.append(DNSRecord(name: link.name, type: DNSCode.typeCNAME, ttl: link.ttl, data: data))
            vetted.chain.append(target)
            current = target
        }
        for record in records where record.type == query.type && record.name == current {
            switch query.type {
            case DNSCode.typeA:
                guard record.data.count == 4 else { continue }
                let address = record.data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if let reason = gate.addressBlock(address, for: query.name) {
                    vetted.stripped = vetted.stripped ?? reason
                } else if vetted.addressesKept < Self.maximumAddresses {
                    vetted.addressesKept += 1
                    vetted.records.append(record)
                }
            case DNSCode.typePTR:
                guard let name = DNSWire.decodeName(record.data), let data = DNSWire.encodeName(name) else { continue }
                vetted.records.append(DNSRecord(name: record.name, type: record.type, ttl: record.ttl, data: data))
            default:
                break
            }
        }
        return vetted
    }

    /// Records each address kept with every name on the chain that led to it.
    private func remember(_ vetted: Vetted, gate: inout PolicyGate, now: TimeInterval) {
        for record in vetted.records where record.type == DNSCode.typeA {
            let address = record.data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let ttl = TimeInterval(min(max(record.ttl, Self.minimumTTL), Self.maximumTTL))
            for name in vetted.chain { gate.names.record(name: name, address: address, ttl: ttl, now: now) }
        }
    }
}

extension DNSReplyRoute {
    fileprivate var isUDP: Bool {
        if case .udp = self { return true }
        return false
    }
}
