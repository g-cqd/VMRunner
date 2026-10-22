import Foundation
package import NetPolicy

// The words for a flow event, in one place so that everything that shows one says the same thing: the app's connection log
// and the headless helper's event lines.

extension FlowTransport {
    package var label: String {
        switch self {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .icmp: "ICMP"
        case .dns: "DNS"
        }
    }
}

extension FlowEvent {
    /// Where the event is about: the name the guest asked for or was given with the address and port, such as
    /// `example.com (93.184.216.34:443)`; a DNS event is just the name.
    package var destinationText: String {
        let address: String
        switch destinationAddress {
        case .v4: address = destinationAddress.description
        case .v6: address = "[\(destinationAddress)]"
        }
        let endpoint = destinationPort == 0 ? address : "\(address):\(destinationPort)"
        guard let destinationName else { return endpoint }
        return transport == .dns ? destinationName : "\(destinationName) (\(endpoint))"
    }

    /// What a DNS answer with this response code means.
    package static func answerText(responseCode code: UInt8) -> String {
        switch code {
        case 0: "Name resolved"
        case 3: "No such name"
        case 5: "Refused"
        default: "Answered (code \(code))"
        }
    }
}

extension FlowDenial {
    /// A plain-language reason, for the log and its tooltips.
    package var explanation: String {
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
    package var explanation: String {
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
