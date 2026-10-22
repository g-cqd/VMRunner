import Foundation

/// One port (`443`) or an inclusive range (`8000-8100`).
///
/// An integer literal is a single port, so `policy.blockedPorts = [22, 23]` reads naturally. Port 0 is never valid
/// traffic and is rejected when parsing text. `Codable` encodes the canonical text.
package struct PortRule: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    let range: ClosedRange<UInt16>

    init(_ port: UInt16) {
        range = port...port
    }

    package init(integerLiteral value: UInt16) {
        self.init(value)
    }

    /// Parses `"443"` or `"8000-8100"`; surrounding whitespace is ignored.
    ///
    /// - Throws: ``NetworkPolicyError/empty`` or ``NetworkPolicyError/invalidPort(_:)`` for anything that is not decimal
    ///   ports in 1...65535 with the lower bound first.
    init(_ text: String) throws(NetworkPolicyError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let pieces = trimmed.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count <= 2, let lower = Self.port(pieces[0]), let upper = pieces.count == 2 ? Self.port(pieces[1]) : lower,
            lower <= upper
        else { throw .invalidPort(text) }
        range = lower...upper
    }

    private static func port(_ text: Substring) -> UInt16? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let value = UInt16(text), value != 0 else {
            return nil
        }
        return value
    }

    func contains(_ port: UInt16) -> Bool { range.contains(port) }

    package var description: String {
        range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
    }

    /// Accepts the canonical text, and a bare JSON number for a single port (how policies were saved before ranges).
    package init(from decoder: any Decoder) throws {
        if let number = try? decoder.singleValueContainer().decode(UInt16.self) {
            self.init(number)
            return
        }
        self = try StringRuleCoding.decode(decoder, kind: "port rule") { try Self($0) }
    }

    package func encode(to encoder: any Encoder) throws {
        try StringRuleCoding.encode(description, to: encoder)
    }
}

/// A destination together with the ports it applies to: `*.example.com:443`, `evil.net:22,8000-8100`,
/// `10.0.0.0/8:22`, `[2001:db8::/32]:443`. No ports means every port.
///
/// This is what lets an allow-list say "only HTTPS to GitHub" instead of "GitHub on any port", and a deny-list say
/// "SSH to this block" without blocking the block entirely. An IPv6 target with ports must be bracketed; a bare IPv6
/// target (more than one colon, no brackets) applies to every port. Domain targets follow ``DomainRule`` (`evil.com`
/// is the exact name, `*.evil.com` its subdomains), address targets follow ``AddressRule``.
package struct ConnectionRule: Hashable, Sendable, Codable, CustomStringConvertible {
    package enum Target: Hashable, Sendable {
        case name(DomainRule)
        case address(AddressRule)
    }

    package let target: Target
    /// Empty means every port.
    let ports: [PortRule]

    /// - Throws: ``NetworkPolicyError/empty``, ``NetworkPolicyError/invalidConnection(_:)`` for broken brackets or an
    ///   empty port list, and the port, address, and domain errors for the parts.
    init(_ text: String) throws(NetworkPolicyError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let (targetText, portsText) = try Self.split(trimmed, original: text)
        if let address = try? AddressRule(targetText) {
            target = .address(address)
        } else {
            target = .name(try DomainRule(targetText))
        }
        ports =
            try portsText.map { text throws(NetworkPolicyError) in
                try text.split(separator: ",", omittingEmptySubsequences: false).map { piece throws(NetworkPolicyError) in
                    try PortRule(String(piece))
                }
            } ?? []
    }

    /// Separates the target from the optional port list.
    private static func split(_ text: String, original: String) throws(NetworkPolicyError) -> (String, String?) {
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw .invalidConnection(original) }
            let target = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (target, nil) }
            guard rest.hasPrefix(":"), rest.count > 1 else { throw .invalidConnection(original) }
            return (target, String(rest.dropFirst()))
        }
        let colons = text.filter { $0 == ":" }.count
        guard colons == 1, let colon = text.lastIndex(of: ":") else { return (text, nil) }
        let portsText = String(text[text.index(after: colon)...])
        guard !portsText.isEmpty else { throw .invalidConnection(original) }
        return (String(text[..<colon]), portsText)
    }

    func appliesToPort(_ port: UInt16) -> Bool {
        ports.isEmpty || ports.contains { $0.contains(port) }
    }

    /// Whether this rule, used as a block, matches the destination: any resolved address inside an address target
    /// (like ``NetworkPolicy/blockedAddresses``), or a name inside a domain target.
    func blocks(host: HostForm, port: UInt16, addresses: [IPAddress]) -> Bool {
        matches(host: host, port: port, addresses: addresses, needing: .anyAddress)
    }

    /// Whether this rule, used as an allow, matches the destination: **every** resolved address inside an address
    /// target (like ``NetworkPolicy/allowedAddresses``), or a name inside a domain target.
    func allows(host: HostForm, port: UInt16, addresses: [IPAddress]) -> Bool {
        matches(host: host, port: port, addresses: addresses, needing: .everyAddress)
    }

    private enum AddressMatch { case anyAddress, everyAddress }

    private func matches(host: HostForm, port: UInt16, addresses: [IPAddress], needing: AddressMatch) -> Bool {
        guard appliesToPort(port) else { return false }
        switch (target, needing) {
        case (.name(let rule), _): return Self.matches(rule, host)
        case (.address(let rule), .anyAddress):
            return addresses.contains { address in address.blockCandidates.contains(where: rule.contains) }
        case (.address(let rule), .everyAddress):
            return !addresses.isEmpty && addresses.allSatisfy { rule.contains($0.normalized) }
        }
    }

    private static func matches(_ rule: DomainRule, _ host: HostForm) -> Bool {
        guard case .name(let name) = host else { return false }
        return rule.matches(name)
    }

    package var description: String {
        var text: String
        switch target {
        case .name(let rule): text = rule.description
        case .address(let rule):
            if case .v6 = rule.network { text = "[\(rule)]" } else { text = rule.description }
        }
        if !ports.isEmpty { text += ":" + ports.map(\.description).joined(separator: ",") }
        return text
    }

    package init(from decoder: any Decoder) throws {
        self = try StringRuleCoding.decode(decoder, kind: "connection rule") { try Self($0) }
    }

    package func encode(to encoder: any Encoder) throws {
        try StringRuleCoding.encode(description, to: encoder)
    }
}
