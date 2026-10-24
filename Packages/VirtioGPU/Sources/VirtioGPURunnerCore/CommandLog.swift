/// The two queues of the device.
public enum GPUQueueKind: UInt16, Sendable {
    case control = 0
    case cursor = 1
}

/// One request as the device handled it.
public struct CommandLogEntry: Equatable, Sendable {
    /// 1 for the first request since the device was created; never reset.
    public let sequence: UInt64
    public let queue: GPUQueueKind
    /// The request's type as the guest sent it (0 when the request was too short to carry one).
    public let commandType: UInt32
    public let resourceID: UInt32
    /// The answer's type; `nil` for a cursor request, which gets no answer.
    public let responseType: GPUResponseType?
    /// The request's length in bytes.
    public let byteCount: Int
}

/// The last requests the device handled, in a ring of fixed capacity, plus counts of every request and answer since the
/// device was created. Memory is bounded whatever the guest sends: one entry per slot, one counter per distinct type.
public struct CommandLog: Sendable {
    public let capacity: Int
    private var ring: [CommandLogEntry] = []
    private var next = 0
    public private(set) var total: UInt64 = 0
    private var commandCounts: [UInt32: UInt64] = [:]
    private var responseCounts: [GPUResponseType: UInt64] = [:]
    /// Distinct command types counted; one past this, further unknown types share the counter of type 0xFFFF_FFFF.
    private static let maxCommandTypes = 64

    public init(capacity: Int = 1024) {
        self.capacity = max(capacity, 1)
        ring.reserveCapacity(self.capacity)
    }

    public mutating func append(_ entry: CommandLogEntry) {
        if ring.count < capacity {
            ring.append(entry)
        } else {
            ring[next] = entry
        }
        next = (next + 1) % capacity
        total += 1
        let type = commandCounts[entry.commandType] != nil || commandCounts.count < Self.maxCommandTypes ? entry.commandType : 0xFFFF_FFFF
        commandCounts[type, default: 0] += 1
        if let response = entry.responseType { responseCounts[response, default: 0] += 1 }
    }

    /// The entries still held, oldest first.
    public var entries: [CommandLogEntry] {
        ring.count < capacity ? ring : Array(ring[next...] + ring[..<next])
    }

    /// One line per request type and per answer type, in hexadecimal order, with how often each was seen.
    public func summary() -> [String] {
        let commands = commandCounts.sorted { $0.key < $1.key }.map { "command 0x\(String($0.key, radix: 16)): \($0.value)" }
        let responses = responseCounts.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            "response 0x\(String($0.key.rawValue, radix: 16)): \($0.value)"
        }
        return ["requests: \(total)"] + commands + responses
    }
}
