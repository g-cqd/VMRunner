import Foundation

/// The kind of traffic a ``FlowEvent`` is about.
enum FlowTransport: String, Sendable, Hashable {
    case tcp, udp, icmp
    /// A DNS query answered by the built-in proxy.
    case dns
}

/// Why an attempt was refused.
enum FlowDenial: Hashable, Sendable {
    /// The network policy said no.
    case policy(NetworkPolicy.Reason)
    /// The guest addressed the gateway on a port the gateway does not serve (only DNS is served).
    case gatewayService(port: UInt16)
    /// The stack is at its flow limit.
    case flowLimit
    /// A destination that cannot be NATed (multicast or broadcast).
    case unroutable
}

/// Why an established flow ended.
enum FlowCloseReason: Hashable, Sendable {
    /// Both directions finished normally (TCP FIN exchange), or a datagram flow was closed after answering.
    case finished
    case guestReset
    /// The host peer reset the connection or the socket failed (`errno`).
    case hostError(Int32)
    /// The host connection could not be established (`errno`; 0 for a timeout).
    case connectFailed(Int32)
    case idleTimeout
    /// The guest stopped acknowledging data.
    case retransmitTimeout
    /// The policy changed and no longer allows this flow.
    case policyRevoked(NetworkPolicy.Reason)
    /// The host's network path changed and flows are reset so the guest reconnects over the new path.
    case hostPathChanged
    case stackStopped
    /// Evicted to make room for a newer flow.
    case evicted
}

/// One thing that happened to one flow, for logs, a UI, or tests.
///
/// Times are seconds on the stack's monotonic clock (the same clock for `time` and `duration`).
struct FlowEvent: Sendable, Hashable {
    enum Phase: Hashable, Sendable {
        /// The flow exists: for TCP, the host connection succeeded and the guest handshake completed.
        case opened
        case denied(FlowDenial)
        case closed(FlowCloseReason)
        /// A DNS query was answered with this RCODE (0 success, 3 NXDOMAIN, 5 REFUSED).
        case answered(responseCode: UInt8)
    }

    /// Unique per flow within one stack; the `opened` and `closed` events of a flow share it.
    let flowID: UInt64
    let transport: FlowTransport
    let phase: Phase
    let destinationAddress: IPAddress
    let destinationPort: UInt16
    /// The DNS name the guest was given for this address (or asked for, for DNS events), if any.
    let destinationName: String?
    let time: TimeInterval
    /// Bytes relayed guest to host and host to guest; set on `closed`, zero otherwise.
    let bytesToHost: UInt64
    let bytesToGuest: UInt64
    /// Lifetime of the flow; set on `closed`, zero otherwise.
    let duration: TimeInterval
    /// How many attempts the event stands for: 1, except for a denial event that sums up the identical refusals held
    /// back since the last one for the same destination (see ``DenialSuppression``). A UI shows "x N" for more than one.
    let count: Int
}

extension FlowEvent {
    /// An event about the flow to `remote`. Traffic counters and duration are zero except on `closed`.
    init(
        flowID: UInt64, transport: FlowTransport, phase: Phase, remote: (address: UInt32, port: UInt16), name: String?,
        time: TimeInterval, bytesToHost: UInt64 = 0, bytesToGuest: UInt64 = 0, duration: TimeInterval = 0, count: Int = 1
    ) {
        self.init(
            flowID: flowID, transport: transport, phase: phase, destinationAddress: .v4(remote.address), destinationPort: remote.port,
            destinationName: name, time: time, bytesToHost: bytesToHost, bytesToGuest: bytesToGuest, duration: duration, count: count)
    }
}

extension FlowDenial {
    /// A short, non-sensitive label for logs (the kind of denial, never the destination).
    var logName: String {
        switch self {
        case .policy: "policy"
        case .gatewayService: "gateway service"
        case .flowLimit: "flow limit"
        case .unroutable: "unroutable"
        }
    }
}

extension FlowCloseReason {
    /// Whether the flow ended abnormally (worth a log line) rather than by a normal finish, idle expiry, or shutdown.
    var isFailure: Bool {
        switch self {
        case .guestReset, .hostError, .connectFailed, .retransmitTimeout: true
        case .finished, .idleTimeout, .policyRevoked, .hostPathChanged, .stackStopped, .evicted: false
        }
    }

    /// A short, non-sensitive label for logs.
    var logName: String {
        switch self {
        case .finished: "finished"
        case .guestReset: "guest reset"
        case .hostError(let code): "host error \(code)"
        case .connectFailed(let code): "connect failed \(code)"
        case .idleTimeout: "idle"
        case .retransmitTimeout: "retransmit timeout"
        case .policyRevoked: "policy revoked"
        case .hostPathChanged: "path changed"
        case .stackStopped: "stopped"
        case .evicted: "evicted"
        }
    }
}
