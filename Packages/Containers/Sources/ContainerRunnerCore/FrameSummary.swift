/// What the runner reads off one Ethernet frame the guest sent: enough to tell that the guest's network device is wired to
/// the host end and what it asked for. Frames are never forwarded anywhere.
public struct FrameSummary: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// ARP "who has `target`, tell `sender`".
        case arpRequest(sender: String, target: String)
        /// ARP "`sender` is at its hardware address".
        case arpReply(sender: String)
        case ipv4(protocolNumber: UInt8, destination: String)
        case ipv6
        case other(etherType: UInt16)
    }

    private static let headerLength = 14
    private static let arpLength = 28
    private static let ipv4HeaderLength = 20

    public let source: String
    public let destination: String
    public let kind: Kind
    public let length: Int

    /// Reads an Ethernet II frame; `nil` when it is shorter than its header or than the packet its EtherType announces.
    public static func parse(_ frame: [UInt8]) -> Self? {
        guard frame.count >= headerLength else { return nil }
        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        let kind: Kind
        switch etherType {
        case 0x0806:
            guard frame.count >= headerLength + arpLength else { return nil }
            let operation = UInt16(frame[20]) << 8 | UInt16(frame[21])
            let sender = address(frame, at: 28)
            switch operation {
            case 1: kind = .arpRequest(sender: sender, target: address(frame, at: 38))
            case 2: kind = .arpReply(sender: sender)
            default: kind = .other(etherType: etherType)
            }
        case 0x0800:
            guard frame.count >= headerLength + ipv4HeaderLength else { return nil }
            kind = .ipv4(protocolNumber: frame[23], destination: address(frame, at: 30))
        case 0x86DD:
            kind = .ipv6
        default:
            kind = .other(etherType: etherType)
        }
        return Self(source: hardware(frame, at: 6), destination: hardware(frame, at: 0), kind: kind, length: frame.count)
    }

    public var description: String {
        let what =
            switch kind {
            case .arpRequest(let sender, let target): "ARP who-has \(target) tell \(sender)"
            case .arpReply(let sender): "ARP reply from \(sender)"
            case .ipv4(let protocolNumber, let destination): "IPv4 protocol \(protocolNumber) to \(destination)"
            case .ipv6: "IPv6"
            case .other(let etherType): "EtherType 0x\(String(etherType, radix: 16))"
            }
        return "\(source) -> \(destination), \(length) bytes, \(what)"
    }

    private static func address(_ frame: [UInt8], at offset: Int) -> String {
        frame[offset..<offset + 4].map(String.init).joined(separator: ".")
    }

    private static func hardware(_ frame: [UInt8], at offset: Int) -> String {
        frame[offset..<offset + 6].map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined(separator: ":")
    }
}

/// What the second check decides from the frames the guest sent while it tried to reach its gateway.
public enum NetworkVerdict: Equatable, Sendable {
    case passed
    /// The guest's network device never delivered a frame to the host end.
    case noFrames
    /// Frames arrived, but none asked for the gateway's hardware address.
    case noRequestForGateway

    /// The guest address of the interface the runner configures, and the gateway it is told to use.
    public static let guestAddress = "198.18.0.2"
    public static let gatewayAddress = "198.18.0.1"

    public static func evaluate(frames: [FrameSummary]) -> Self {
        guard !frames.isEmpty else { return .noFrames }
        let asked = frames.contains { frame in
            if case .arpRequest(_, let target) = frame.kind { target == gatewayAddress } else { false }
        }
        return asked ? .passed : .noRequestForGateway
    }

    public var summary: String {
        switch self {
        case .passed: "passed"
        case .noFrames: "failed: no frame reached the host end of the link"
        case .noRequestForGateway: "failed: frames arrived but none asked for \(Self.gatewayAddress)"
        }
    }
}
