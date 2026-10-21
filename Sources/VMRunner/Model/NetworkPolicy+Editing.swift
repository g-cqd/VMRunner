import Foundation

/// One of the rule lists a person can edit. The editor builds its sections from this, so adding a list is one case.
enum PolicyList: String, CaseIterable, Identifiable, Sendable {
    case allowedDomains, allowedAddresses, allowedPorts, allowedConnections, allowedURLPrefixes
    case blockedDomains, blockedAddresses, blockedPorts, blockedConnections, blockedURLPrefixes

    enum Kind: Sendable {
        case domain, address, port, connection, urlPrefix
    }

    var id: Self { self }

    static let allowLists = allCases.filter(\.isAllow)
    static let blockLists = allCases.filter { !$0.isAllow }

    var isAllow: Bool {
        switch self {
        case .allowedDomains, .allowedAddresses, .allowedPorts, .allowedConnections, .allowedURLPrefixes: true
        default: false
        }
    }

    var kind: Kind {
        switch self {
        case .allowedDomains, .blockedDomains: .domain
        case .allowedAddresses, .blockedAddresses: .address
        case .allowedPorts, .blockedPorts: .port
        case .allowedConnections, .blockedConnections: .connection
        case .allowedURLPrefixes, .blockedURLPrefixes: .urlPrefix
        }
    }

    var title: String {
        switch kind {
        case .domain: "Domains"
        case .address: "IP addresses"
        case .port: "Ports"
        case .connection: "Connections"
        case .urlPrefix: "URL prefixes"
        }
    }

    /// A placeholder showing the syntax.
    var example: String {
        switch kind {
        case .domain: "example.com or *.example.com"
        case .address: "203.0.113.7 or 203.0.113.0/24"
        case .port: "443 or 8000-8100"
        case .connection: "example.com:443 or 10.0.0.0/8:22,80"
        case .urlPrefix: "http://example.com/downloads"
        }
    }

    /// What the list does, for a tooltip.
    var tooltip: String {
        let verb = isAllow ? "allowed" : "blocked"
        switch kind {
        case .domain:
            return "Names that are \(verb). example.com is that exact name; *.example.com is every subdomain but not example.com itself."
        case .address:
            return "IPv4 or IPv6 addresses and CIDR blocks that are \(verb), such as 203.0.113.0/24."
        case .port:
            return "Destination ports that are \(verb): one port (443) or a range (8000-8100)."
        case .connection:
            return "A destination together with its ports that is \(verb): example.com:443, or 10.0.0.0/8:22 for SSH only."
        case .urlPrefix:
            return "Plain http:// addresses that are \(verb), matched by path prefix. Encrypted https paths can't be seen."
        }
    }
}

extension NetworkPolicy {
    /// The rules of one list in their canonical text form, in the order they are checked.
    func rules(in list: PolicyList) -> [String] {
        switch list {
        case .allowedDomains: allowedDomains.map(\.description)
        case .allowedAddresses: allowedAddresses.map(\.description)
        case .allowedPorts: allowedPorts.map(\.description)
        case .allowedConnections: allowedConnections.map(\.description)
        case .allowedURLPrefixes: allowedURLPrefixes.map(\.description)
        case .blockedDomains: blockedDomains.map(\.description)
        case .blockedAddresses: blockedAddresses.map(\.description)
        case .blockedPorts: blockedPorts.map(\.description)
        case .blockedConnections: blockedConnections.map(\.description)
        case .blockedURLPrefixes: blockedURLPrefixes.map(\.description)
        }
    }

    /// Parses `text` as a rule of this list's kind and appends it, unless an equal rule is already there.
    ///
    /// - Throws: the engine's own parse error (``NetworkPolicyError``); the policy is unchanged then.
    mutating func add(_ text: String, to list: PolicyList) throws(NetworkPolicyError) {
        switch list {
        case .allowedDomains: Self.insert(try DomainRule(text), into: &allowedDomains)
        case .allowedAddresses: Self.insert(try AddressRule(text), into: &allowedAddresses)
        case .allowedPorts: Self.insert(try PortRule(text), into: &allowedPorts)
        case .allowedConnections: Self.insert(try ConnectionRule(text), into: &allowedConnections)
        case .allowedURLPrefixes: Self.insert(try URLRule(text), into: &allowedURLPrefixes)
        case .blockedDomains: Self.insert(try DomainRule(text), into: &blockedDomains)
        case .blockedAddresses: Self.insert(try AddressRule(text), into: &blockedAddresses)
        case .blockedPorts: Self.insert(try PortRule(text), into: &blockedPorts)
        case .blockedConnections: Self.insert(try ConnectionRule(text), into: &blockedConnections)
        case .blockedURLPrefixes: Self.insert(try URLRule(text), into: &blockedURLPrefixes)
        }
    }

    /// Removes the rule at `index`; an index out of range is ignored.
    mutating func remove(at index: Int, from list: PolicyList) {
        switch list {
        case .allowedDomains: Self.remove(at: index, from: &allowedDomains)
        case .allowedAddresses: Self.remove(at: index, from: &allowedAddresses)
        case .allowedPorts: Self.remove(at: index, from: &allowedPorts)
        case .allowedConnections: Self.remove(at: index, from: &allowedConnections)
        case .allowedURLPrefixes: Self.remove(at: index, from: &allowedURLPrefixes)
        case .blockedDomains: Self.remove(at: index, from: &blockedDomains)
        case .blockedAddresses: Self.remove(at: index, from: &blockedAddresses)
        case .blockedPorts: Self.remove(at: index, from: &blockedPorts)
        case .blockedConnections: Self.remove(at: index, from: &blockedConnections)
        case .blockedURLPrefixes: Self.remove(at: index, from: &blockedURLPrefixes)
        }
    }

    /// Why `text` is not a valid rule for `list`, or `nil` if it is.
    static func problem(with text: String, for list: PolicyList) -> NetworkPolicyError? {
        var probe = NetworkPolicy()
        do {
            try probe.add(text, to: list)
            return nil
        } catch {
            return error
        }
    }

    private static func insert<Rule: Equatable>(_ rule: Rule, into rules: inout [Rule]) {
        if !rules.contains(rule) { rules.append(rule) }
    }

    private static func remove<Rule>(at index: Int, from rules: inout [Rule]) {
        if rules.indices.contains(index) { rules.remove(at: index) }
    }
}
