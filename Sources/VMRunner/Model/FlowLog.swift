import Foundation
import NetPolicy

/// One line of the recent-connections log: what the guest tried to reach and what the policy decided.
struct FlowLogEntry: Identifiable, Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        case allowed, denied
    }

    /// Increases with arrival order within one machine run.
    let id: Int
    let outcome: Outcome
    let transport: FlowTransport
    /// The name the guest asked for or was given, with the address and port, such as `example.com (93.184.216.34:443)`.
    let destination: String
    /// Why: the matching rule for a denial, or the plain outcome for an allowed connection.
    let detail: String
    /// How many attempts the line stands for: more than one when identical refusals were folded together ("x 40").
    let count: Int

    /// How many attempts an event stands for: more than one when identical refusals were folded together.
    static func attempts(of event: FlowEvent) -> Int { max(event.count, 1) }

    /// What the log says about a phase, or `nil` when it has no line. Decided without building the line, so a flood of events
    /// can be counted cheaply.
    static func outcome(of phase: FlowEvent.Phase) -> Outcome? {
        switch phase {
        case .opened, .answered: .allowed
        case .denied, .closed(.policyRevoked): .denied
        case .closed: nil
        }
    }

    /// The log line for `event`, or `nil` for events that are not worth a line (a connection ending normally).
    init?(event: FlowEvent, id: Int) {
        self.id = id
        transport = event.transport
        destination = Self.describe(event)
        count = Self.attempts(of: event)
        switch event.phase {
        case .opened:
            outcome = .allowed
            detail = "Allowed"
        case .denied(let denial):
            outcome = .denied
            detail = count > 1 ? "\(denial.explanation) × \(count)" : denial.explanation
        case .answered(let code):
            outcome = .allowed
            detail = Self.describeAnswer(code)
        case .closed(.policyRevoked(let reason)):
            outcome = .denied
            detail = "Closed after a policy change: \(reason.explanation)"
        case .closed:
            return nil
        }
    }

    private static func describe(_ event: FlowEvent) -> String {
        let address: String
        switch event.destinationAddress {
        case .v4: address = event.destinationAddress.description
        case .v6: address = "[\(event.destinationAddress)]"
        }
        let endpoint = event.destinationPort == 0 ? address : "\(address):\(event.destinationPort)"
        guard let name = event.destinationName else { return endpoint }
        return event.transport == .dns ? name : "\(name) (\(endpoint))"
    }

    private static func describeAnswer(_ code: UInt8) -> String {
        switch code {
        case 0: "Name resolved"
        case 3: "No such name"
        case 5: "Refused"
        default: "Answered (code \(code))"
        }
    }
}

extension FlowTransport {
    var label: String {
        switch self {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .icmp: "ICMP"
        case .dns: "DNS"
        }
    }
}

extension FlowDenial {
    /// A plain-language reason, for the log and its tooltips.
    var explanation: String {
        switch self {
        case .policy(let reason): reason.explanation
        case .gatewayService(let port): "Only DNS is served at the gateway (port \(port) is not)."
        case .flowLimit: "Too many connections are open at once."
        case .unroutable: "Multicast and broadcast traffic isn't forwarded."
        }
    }
}

extension NetworkPolicy.Reason {
    /// A plain-language reason naming the rule that decided.
    var explanation: String {
        switch self {
        case .malformedHost: "The destination name is malformed."
        case .nonCanonicalAddress: "The address is written in an unusual form that could hide where it really points."
        case .malformedURL: "The URL could not be understood."
        case .unsupportedScheme(let scheme): "Only http and https URLs are judged (\(scheme) is not)."
        case .blockedPort(let port): "Port \(port) is blocked."
        case .blockedConnection(let rule): "Matches the blocked connection \(rule)."
        case .portNotAllowListed(let port): "Port \(port) is not on the allowed ports."
        case .urlNotAllowListed: "The URL does not start with an allowed prefix."
        case .reservedRange(let kind, let address):
            "\(address) is \(kind.explanation), and "
                + (kind.isFloor ? "the guest is never let reach those." : "private ranges are blocked.")
        case .blockedAddress(let rule, let address): "\(address) is inside the blocked address rule \(rule)."
        case .blockedDomain(let rule): "The name matches the blocked domain \(rule)."
        case .blockedURL(let rule): "The URL starts with the blocked prefix \(rule)."
        case .notAllowListed: "Not on the allow-list."
        case .unresolved: "The name did not resolve to an address."
        case .reservedName: "Names ending in .local or .arpa are not looked up for the guest."
        }
    }
}

extension ReservedRangeKind {
    fileprivate var explanation: String {
        switch self {
        case .cloudMetadata: "a cloud metadata address"
        case .hostGateway: "your Mac's side of the virtual network"
        case .privateNetwork: "a private network address"
        case .loopback: "a loopback address"
        case .linkLocal: "a link-local address"
        case .carrierGradeNAT: "a shared (carrier-grade NAT) address"
        case .uniqueLocal, .siteLocal: "a local IPv6 address"
        case .multicast: "a multicast address"
        case .unspecified: "an unspecified address"
        case .reserved: "a reserved address"
        case .benchmarking: "in the range the virtual network itself uses"
        }
    }
}

/// The host's and the guest's VPN signals side by side, with the wording and symbol to show for them.
///
/// Both are heuristics. The host signal says a tunnel interface is up on the Mac; the guest signal says the traffic
/// leaving the guest looks like a VPN handshake. Neither proves where a particular packet goes.
struct VPNIndicator: Equatable, Sendable {
    enum Level: Sendable {
        /// Nothing to report.
        case quiet
        /// The Mac has a VPN up.
        case hostVPN
        /// The guest seems to run its own VPN, which the filter cannot see into.
        case guestVPN
    }

    let host: VPNState
    let guest: GuestVPNState

    var level: Level {
        if guest.kind != nil { .guestVPN } else if host == .active { .hostVPN } else { .quiet }
    }

    var hostText: String {
        switch host {
        case .active: "Mac VPN: active"
        case .inactive: "Mac VPN: not detected"
        case .unknown: "Mac VPN: unknown"
        }
    }

    var guestText: String {
        guard case .suspected(let kind, let confidence, _, _) = guest else { return "Guest VPN: not detected" }
        return "Guest VPN: \(kind.label) suspected (\(confidence.label) confidence)"
    }

    /// What the detector saw, strongest first, at most three lines.
    var guestEvidence: [String] {
        guard case .suspected(_, _, _, let evidence) = guest else { return [] }
        return evidence.prefix(3).map(\.reason)
    }

    var symbol: String {
        switch level {
        case .quiet: "network.badge.shield.half.filled"
        case .hostVPN: "lock.shield"
        case .guestVPN: "exclamationmark.shield"
        }
    }
}

extension GuestVPNKind {
    var label: String {
        switch self {
        case .wireGuard: "WireGuard"
        case .openVPN: "OpenVPN"
        case .ipsec: "IPsec"
        case .l2tp: "L2TP"
        case .pptp: "PPTP"
        case .dnsHint: "VPN"
        }
    }
}

extension GuestVPNConfidence {
    var label: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}
