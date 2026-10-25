public import Foundation

/// What a machine is doing, as the control service reports it.
public enum ControlState: String, Codable, CaseIterable, Sendable {
    case stopped, starting, running, shuttingDown, pausing, paused, resuming, suspending, stopping
}

/// A machine as an agent sees it.
public struct ControlMachine: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// `macOS`, `linux` or `windows`. A container machine reports `linux`: the container runs a Linux userland, and `guest` has only
    /// ever named an operating system, so a client that switches on it keeps working. Tell a container from a virtual
    /// machine by `workload`.
    public let guest: String
    public let state: ControlState
    /// Only machines whose agent access is on are listed or acted on.
    public let agentAccess: Bool
    /// What the machine runs: `vm` (a virtual machine) or `container`. A member added later than the others: an answer
    /// without it (from a service that predates containers) reads as `vm`, and a client that does not know it ignores it.
    public let workload: String

    public init(id: UUID, name: String, guest: String, state: ControlState, agentAccess: Bool, workload: String = "vm") {
        self.id = id
        self.name = name
        self.guest = guest
        self.state = state
        self.agentAccess = agentAccess
        self.workload = workload
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        guest = try values.decode(String.self, forKey: .guest)
        state = try values.decode(ControlState.self, forKey: .state)
        agentAccess = try values.decode(Bool.self, forKey: .agentAccess)
        workload = try values.decodeIfPresent(String.self, forKey: .workload) ?? "vm"
    }
}

/// What a start or a stop came to.
public enum ControlOutcome: Equatable, Sendable {
    case done(ControlState)
    /// Not done, with a sentence that says why.
    case refused(String)
}

/// What reading a container's log came to.
public enum ControlLogOutcome: Equatable, Sendable {
    /// The end of the log, and whether the log held more than it.
    case text(String, truncated: Bool)
    /// Not read, with a sentence that says why.
    case refused(String)
}

/// The answer of `machines.log`: the end of a container's output log, at most ``maxBytes`` of it.
public struct ControlLog: Codable, Equatable, Sendable {
    /// The most bytes of text an answer holds.
    public static let maxBytes = 65_536

    public let id: UUID
    public let text: String
    /// Whether the log held more than `text`.
    public let truncated: Bool

    public init(id: UUID, text: String, truncated: Bool) {
        self.id = id
        self.text = text
        self.truncated = truncated
    }

    /// The last `limit` bytes of `text`, cut forward to the start of a character, and whether anything was cut. The service,
    /// the app and `vmr control log` all keep the end of a log with it.
    public static func end(of text: String, bytes limit: Int) -> (text: String, cut: Bool) {
        let bytes = text.utf8
        guard limit >= 0, bytes.count > limit else { return (text, false) }
        var start = bytes.index(bytes.endIndex, offsetBy: -limit)
        while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 { start = bytes.index(after: start) }
        return (String(Substring(bytes[start...])), true)
    }
}

/// The machines the service acts on: the app's library, or a fake in tests.
public protocol ControlMachines: Sendable {
    func machines() async -> [ControlMachine]
    func start(_ id: UUID) async -> ControlOutcome
    func stop(_ id: UUID, force: Bool) async -> ControlOutcome
    /// The end of a container machine's output log. A machine that is not a container has none.
    func log(_ id: UUID) async -> ControlLogOutcome
}

/// The methods of the control service, each needing one capability.
public enum ControlMethod: String, CaseIterable, Sendable {
    case list = "machines.list"
    case state = "machines.state"
    case start = "machines.start"
    case stop = "machines.stop"
    case log = "machines.log"

    public var capability: ControlCapability {
        switch self {
        case .list: .list
        case .state: .state
        case .start: .start
        case .stop: .stop
        case .log: .log
        }
    }

    /// The members its `params` may hold.
    var parameters: Set<String> {
        switch self {
        case .list: ["token"]
        case .state, .start, .log: ["token", "machine"]
        case .stop: ["token", "machine", "force"]
        }
    }
}

/// A refused call, as it is logged. It has no field for a token, so what is logged can never hold one.
public struct ControlDenial: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case otherUser = "the client runs as another user"
        case noToken = "no token"
        case unknownToken = "an unknown or revoked token"
        case missingCapability = "the token lacks the capability"
        case outsideScope = "the machine is not one of the token's"
        case agentAccessOff = "agent access is off for the machine"
    }

    public let reason: Reason
    public let method: ControlMethod?
    public let tokenID: UUID?
    public let machine: UUID?
    /// The user id of a client that runs as another user.
    public let peerUser: UInt32?

    public init(
        reason: Reason, method: ControlMethod? = nil, tokenID: UUID? = nil, machine: UUID? = nil, peerUser: UInt32? = nil
    ) {
        self.reason = reason
        self.method = method
        self.tokenID = tokenID
        self.machine = machine
        self.peerUser = peerUser
    }

    /// What was refused and why, without any identifier: safe to log in the clear.
    public var summary: String {
        let what = method.map { "\($0.rawValue) refused" } ?? "connection refused"
        return peerUser.map { "\(what): \(reason.rawValue) (user \($0))" } ?? "\(what): \(reason.rawValue)"
    }
}
