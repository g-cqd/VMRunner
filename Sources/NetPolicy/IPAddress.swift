import Foundation
import Network

/// An IPv4 or IPv6 address as a plain value, so rules can be compared with integer arithmetic.
///
/// This type deliberately shadows `Network.IPAddress` (a protocol that is neither `Hashable` nor `Codable`)
/// inside this module. Text is parsed with Network's `IPv4Address` / `IPv6Address` after a strict syntax gate:
/// only canonical dotted-quad IPv4 (four decimal parts, no leading zeros) and RFC 4291 IPv6 are accepted, because
/// Network (like `inet_aton`) also accepts `127.1`, `2130706433`, and `0x7f000001`, and reads `0177.0.0.1` as
/// *decimal* where most resolvers read it as octal. Those spellings are the classic filter bypasses; see
/// ``HostForm`` for how they are handled.
///
/// `Codable` encodes the canonical text form (`"10.0.0.1"`, `"fe80::1"`) and decoding re-validates it.
package enum IPAddress: Hashable, Sendable {
    case v4(UInt32)
    case v6(UInt128)

    /// Parses a canonical IPv4 or IPv6 literal. Returns `nil` for anything else, including IPv6 zone
    /// identifiers (`fe80::1%en0`), bracketed hosts, legacy IPv4 spellings, and surrounding whitespace.
    package init?(strictLiteral text: String) {
        if text.contains(":") {
            guard !text.contains("%"), Self.hasCanonicalDottedTail(text), let parsed = IPv6Address(text) else { return nil }
            self = .v6(Self.bits(of: parsed.rawValue))
        } else {
            guard Self.isCanonicalIPv4(text), let parsed = IPv4Address(text) else { return nil }
            self = .v4(UInt32(truncatingIfNeeded: Self.bits(of: parsed.rawValue)))
        }
    }

    /// Whether `text` is exactly four decimal parts of 0...255 with no signs and no leading zeros.
    static func isCanonicalIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
            return (part.utf8.count == 1 || part.utf8.first != 0x30) && UInt8(part) != nil
        }
    }

    /// The part after the last colon of an IPv6 literal must be canonical IPv4 when it contains a dot
    /// (`::ffff:010.0.0.1` is ambiguous between octal and decimal and is rejected).
    private static func hasCanonicalDottedTail(_ text: String) -> Bool {
        guard text.contains("."), let colon = text.lastIndex(of: ":") else { return true }
        return isCanonicalIPv4(String(text[text.index(after: colon)...]))
    }

    private static func bits(of data: Data) -> UInt128 {
        data.reduce(0) { ($0 << 8) | UInt128($1) }
    }

    /// The address with IPv4-mapped IPv6 (`::ffff:a.b.c.d`) replaced by the IPv4 address it denotes.
    /// All other addresses are returned unchanged.
    var normalized: Self {
        if case .v6(let bits) = self, bits >> 32 == 0xFFFF { return .v4(UInt32(truncatingIfNeeded: bits)) }
        return self
    }

    /// Every address a *block* rule must be tested against: the address itself, its mapped form, and the
    /// IPv4 address embedded by IPv4-compatible (`::a.b.c.d`), NAT64 (`64:ff9b::/96`), and 6to4 (`2002::/16`)
    /// encodings. Testing all of them means a block on `10.0.0.0/8` also catches `64:ff9b::a00:1`.
    var blockCandidates: [Self] {
        guard case .v6(let bits) = self else { return [self] }
        var candidates = [self]
        let normalized = normalized
        if normalized != self { candidates.append(normalized) }
        let low = UInt32(truncatingIfNeeded: bits)
        if bits >> 32 == 0 || bits >> 32 == 0x0064_FF9B_0000_0000_0000_0000 {
            candidates.append(.v4(low))
        } else if bits >> 112 == 0x2002 {
            candidates.append(.v4(UInt32(truncatingIfNeeded: bits >> 80)))
        }
        return candidates
    }
}

extension IPAddress: CustomStringConvertible {
    /// Canonical text: dotted quad, or RFC 5952 compressed lower-case IPv6.
    package var description: String {
        switch self {
        case .v4(let bits): [24, 16, 8, 0].map { String((bits >> $0) & 0xFF) }.joined(separator: ".")
        case .v6(let bits): Self.formatIPv6(bits)
        }
    }

    private static func formatIPv6(_ bits: UInt128) -> String {
        let groups = (0..<8).map { UInt16(truncatingIfNeeded: bits >> (112 - 16 * $0)) }
        var best = (start: 0, length: 0)
        var index = 0
        while index < groups.count {
            guard groups[index] == 0 else {
                index += 1
                continue
            }
            var end = index
            while end < groups.count, groups[end] == 0 { end += 1 }
            if end - index > best.length { best = (index, end - index) }
            index = end
        }
        func join(_ slice: ArraySlice<UInt16>) -> String { slice.map { String($0, radix: 16) }.joined(separator: ":") }
        guard best.length >= 2 else { return join(groups[...]) }
        return join(groups[..<best.start]) + "::" + join(groups[(best.start + best.length)...])
    }
}

extension IPAddress: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let address = IPAddress(strictLiteral: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an IP address: \(text)")
        }
        self = address
    }

    package func encode(to encoder: any Encoder) throws {
        try StringRuleCoding.encode(description, to: encoder)
    }
}

/// A single address (`10.0.0.1`) or CIDR block (`10.0.0.0/8`, `fd00::/8`).
///
/// Host bits set in the rule are cleared, not rejected: `10.1.2.3/8` is the block `10.0.0.0/8` (as in Go's
/// `Prefix.Masked`). The canonical form is what ``description`` and `Codable` produce. A bare address means
/// `/32` or `/128`. `/0` matches every address of its family. IPv6 rules inside `::ffff:0:0/96` with a prefix of
/// at least 96 are stored as the equivalent IPv4 rule, since evaluation treats mapped addresses as IPv4.
package struct AddressRule: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The first address of the block (host bits cleared).
    let network: IPAddress
    /// Number of leading bits that must match: 0...32 for IPv4, 0...128 for IPv6.
    let prefixLength: Int

    /// Parses `"address"` or `"address/prefix"`; surrounding whitespace is ignored.
    ///
    /// - Throws: ``NetworkPolicyError/empty``, ``NetworkPolicyError/invalidAddress(_:)`` when the address is not a
    ///   canonical literal, ``NetworkPolicyError/invalidPrefixLength(_:)`` when the prefix is not a decimal
    ///   number within the family's range.
    init(_ text: String) throws(NetworkPolicyError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let pieces = trimmed.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count <= 2, let address = IPAddress(strictLiteral: String(pieces[0])) else { throw .invalidAddress(text) }
        let width = Self.width(of: address)
        var prefix = width
        if pieces.count == 2 {
            let prefixText = pieces[1]
            guard !prefixText.isEmpty, prefixText.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                let value = Int(prefixText), value <= width
            else { throw .invalidPrefixLength(text) }
            prefix = value
        }
        self.init(network: address, prefixLength: prefix)
    }

    /// Builds a rule, clamping `prefixLength` into the family's range and clearing host bits. Total by design:
    /// used for the built-in range tables.
    init(network: IPAddress, prefixLength: Int) {
        var base = network
        var prefix = prefixLength
        if case .v6(let bits) = network, bits >> 32 == 0xFFFF, prefixLength >= 96 {
            base = .v4(UInt32(truncatingIfNeeded: bits))
            prefix -= 96
        }
        prefix = min(max(prefix, 0), Self.width(of: base))
        switch base {
        case .v4(let bits): self.network = .v4(bits & Self.mask4(prefix))
        case .v6(let bits): self.network = .v6(bits & Self.mask6(prefix))
        }
        self.prefixLength = prefix
    }

    /// Whether `address` lies inside the block. An IPv4 rule never matches an IPv6 address and vice versa
    /// (callers test mapped forms via ``IPAddress/blockCandidates``).
    func contains(_ address: IPAddress) -> Bool {
        switch (network, address) {
        case (.v4(let base), .v4(let bits)): bits & Self.mask4(prefixLength) == base
        case (.v6(let base), .v6(let bits)): bits & Self.mask6(prefixLength) == base
        default: false
        }
    }

    package var description: String {
        let isHost = prefixLength == Self.width(of: network)
        return isHost ? network.description : "\(network)/\(prefixLength)"
    }

    private static func width(of address: IPAddress) -> Int {
        switch address {
        case .v4: 32
        case .v6: 128
        }
    }

    private static func mask4(_ prefix: Int) -> UInt32 { UInt32.max << (32 - prefix) }
    private static func mask6(_ prefix: Int) -> UInt128 { UInt128.max << (128 - prefix) }

    package init(from decoder: any Decoder) throws {
        self = try StringRuleCoding.decode(decoder, kind: "address rule") { try Self($0) }
    }

    package func encode(to encoder: any Encoder) throws {
        try StringRuleCoding.encode(description, to: encoder)
    }
}

/// Why an address is considered non-public.
///
/// Two groups: the *floor* (see ``isFloor``), which no policy setting lifts, and the rest, which
/// ``NetworkPolicy/blockPrivateRanges`` governs.
package enum ReservedRangeKind: String, Hashable, Sendable {
    /// `169.254.169.254`, the instance-metadata endpoint of the major clouds.
    case cloudMetadata
    /// `192.168.64.0/24`: the host's side of the Virtualization.framework NAT network (gateway, DNS, host services).
    case hostGateway
    /// RFC 1918 and other private networks.
    case privateNetwork
    case loopback
    case linkLocal
    /// `100.64.0.0/10`, shared address space (carrier-grade NAT; also used by Tailscale and similar).
    case carrierGradeNAT
    /// `fc00::/7`.
    case uniqueLocal
    /// Deprecated site-local `fec0::/10`.
    case siteLocal
    case multicast
    /// `0.0.0.0/8` and `::`.
    case unspecified
    /// `240.0.0.0/4`, including the limited broadcast address.
    case reserved
    /// `198.18.0.0/15` (RFC 2544): where the user-mode network puts its gateway and guest, so never a destination.
    case benchmarking

    /// Whether the range is part of the floor: the guest's own host, its virtual network and the addresses that name
    /// the machine or its cloud (loopback, unspecified, link-local and metadata, the NAT gateway and the user-mode
    /// network's range). They are denied whatever the policy says, because reaching them reaches the Mac itself, which
    /// no list of rules is meant to grant by accident. The other kinds are other people's networks, which
    /// ``NetworkPolicy/blockPrivateRanges`` governs.
    package var isFloor: Bool {
        switch self {
        case .cloudMetadata, .hostGateway, .loopback, .linkLocal, .unspecified, .benchmarking: true
        case .privateNetwork, .carrierGradeNAT, .uniqueLocal, .siteLocal, .multicast, .reserved: false
        }
    }
}

/// The built-in non-public ranges: the floor (always enforced) and the private networks `NetworkPolicy.blockPrivateRanges`
/// governs.
package enum ReservedRanges {
    private static func v4(_ bits: UInt32, _ prefix: Int, _ kind: ReservedRangeKind) -> (kind: ReservedRangeKind, rule: AddressRule) {
        (kind, AddressRule(network: .v4(bits), prefixLength: prefix))
    }

    private static func v6(_ high: UInt128, _ prefix: Int, _ kind: ReservedRangeKind) -> (kind: ReservedRangeKind, rule: AddressRule) {
        (kind, AddressRule(network: .v6(high << 112), prefixLength: prefix))
    }

    /// Ordered most specific first, so the reported kind is the most informative one.
    static let table: [(kind: ReservedRangeKind, rule: AddressRule)] = [
        v4(0xA9FE_A9FE, 32, .cloudMetadata),
        v4(0xC0A8_4000, 24, .hostGateway),
        v4(0x0A00_0000, 8, .privateNetwork),
        v4(0xAC10_0000, 12, .privateNetwork),
        v4(0xC0A8_0000, 16, .privateNetwork),
        v4(0x7F00_0000, 8, .loopback),
        v4(0xA9FE_0000, 16, .linkLocal),
        v4(0x6440_0000, 10, .carrierGradeNAT),
        v4(0xC612_0000, 15, .benchmarking),
        v4(0xE000_0000, 4, .multicast),
        v4(0x0000_0000, 8, .unspecified),
        v4(0xF000_0000, 4, .reserved),
        (.loopback, AddressRule(network: .v6(1), prefixLength: 128)),
        (.unspecified, AddressRule(network: .v6(0), prefixLength: 128)),
        v6(0xFE80, 10, .linkLocal),
        v6(0xFEC0, 10, .siteLocal),
        v6(0xFC00, 7, .uniqueLocal),
        v6(0xFF00, 8, .multicast),
    ]

    /// The kind of the first built-in range containing `address`, or `nil` for a public address.
    /// - Complexity: O(1); the table is a fixed size.
    static func kind(of address: IPAddress) -> ReservedRangeKind? {
        table.first { $0.rule.contains(address) }?.kind
    }

    /// The kind of the first range containing `address` that is enforced: always the floor, and the private networks
    /// only when `blockingPrivateRanges`. `exempting` names floor kinds to let through (see
    /// ``NetworkPolicy/evaluate(host:port:resolvedAddresses:exempting:)``).
    static func enforcedKind(
        of address: IPAddress, blockingPrivateRanges: Bool, exempting: Set<ReservedRangeKind> = []
    ) -> ReservedRangeKind? {
        table.first { entry in
            guard entry.rule.contains(address), !exempting.contains(entry.kind) else { return false }
            return entry.kind.isFloor || blockingPrivateRanges
        }?.kind
    }
}
