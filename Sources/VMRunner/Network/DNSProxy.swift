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
/// - **Policy** is consulted twice: before resolving (``PolicyGate/nameBlock(for:)``: a blocked domain gets NXDOMAIN
///   or REFUSED, never reaching the resolver), and after (every CNAME target is checked too, so a harmless name
///   cannot launder a blocked one). Everything else is judged per connection.
/// - **Memory**: every address in a successful answer is remembered with its names in the gate's ``NameTable``.
/// - **IPv6**: the guest has no IPv6, so AAAA questions get an empty NOERROR answer (after the policy check) and
///   guests use IPv4 without waiting for a timeout.
final class DNSProxy {
    private struct Pending {
        let query: DNSQuery
        let route: DNSReplyRoute
        let server: UInt32
        let deadline: TimeInterval
    }

    private static let maximumPending = 256
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
        if let reason = gate.nameBlock(for: query.name) {
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
        for record in result.records where record.name != query.name {
            if let reason = gate.nameBlock(for: record.name) {
                ctx.stats.dnsBlocked += 1
                return answer(blockCode(ctx.config), denial: reason)
            }
        }
        remember(result, query: query, gate: &gate, now: ctx.now)
        return answer(result.responseCode, records: result.records)
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

    /// Records each address with the queried name and every name on the CNAME chain.
    private func remember(_ result: DNSLookupResult, query: DNSQuery, gate: inout PolicyGate, now: TimeInterval) {
        let chain = Set(result.records.filter { $0.type == DNSCode.typeCNAME || $0.type == DNSCode.typeA }.map(\.name) + [query.name])
        for record in result.records where record.type == DNSCode.typeA && record.data.count == 4 {
            let address = record.data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let ttl = TimeInterval(min(max(record.ttl, Self.minimumTTL), Self.maximumTTL))
            for name in chain { gate.names.record(name: name, address: address, ttl: ttl, now: now) }
        }
    }
}

extension DNSReplyRoute {
    fileprivate var isUDP: Bool {
        if case .udp = self { return true }
        return false
    }
}
