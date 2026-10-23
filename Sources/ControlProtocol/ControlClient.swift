public import Foundation
import GuestConsole
import Synchronization

/// Why a client call failed.
public enum ControlClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case closed
    case timedOut
    case answerTooLong
    case malformedAnswer
    case system(Int32)
    /// The process serving the socket runs as another user, so nothing was sent to it.
    case peerIsAnotherUser

    public var description: String {
        switch self {
        case .closed: "the control service closed the connection without an answer"
        case .timedOut: "the control service did not answer in time"
        case .answerTooLong: "the control service's answer is longer than this client accepts"
        case .malformedAnswer: "the control service's answer is not a JSON-RPC 2.0 answer this client can read"
        case .system(let code): "a system call failed (errno \(code))"
        case .peerIsAnotherUser: "the socket is served by a process of another user; nothing was sent to it"
        }
    }
}

/// An answer as the client reads it.
public struct ControlAnswer: Equatable, Sendable {
    /// The deepest nesting of objects and arrays an answer may have; `machines.list` needs four. The system parser recurses
    /// with the nesting, so a deeper answer is refused unparsed, as the service refuses a deep request.
    public static let deepestNesting = 8

    public let id: Int?
    public let errorCode: Int?
    public let errorMessage: String?
    /// The `result` member as JSON with sorted keys; nil for an error.
    public let result: Data?

    init(line: Data) throws {
        guard RPCMessage.nesting(of: line) <= Self.deepestNesting,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["jsonrpc"] as? String == "2.0"
        else { throw ControlClientError.malformedAnswer }
        id = object["id"] as? Int
        if let error = object["error"] as? [String: Any] {
            errorCode = error["code"] as? Int
            errorMessage = error["message"] as? String
            result = nil
        } else if let value = object["result"] {
            errorCode = nil
            errorMessage = nil
            result = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        } else {
            throw ControlClientError.malformedAnswer
        }
    }
}

/// A blocking client of the control service. Answers are read through one buffer that lives as long as the client, so
/// requests may be sent ahead of their answers (pipelined): an answer that arrives in the same read as the one before it
/// waits in the buffer for the next `receive()`. The tests drive the protocol end to end with it; the command-line client
/// and the MCP server call the service through it.
public final class ControlClient: Sendable {
    /// The longest answer line a client accepts by default, in bytes.
    public static let defaultAnswerBytes = 1 << 20

    public let descriptor: Int32
    /// How long a call waits for the service to take the request and to answer: longer than the service's own 120 s limit
    /// for an answer, so a slow start is answered rather than abandoned.
    public let timeoutMilliseconds: Int32
    /// What has been read and not yet returned: the rest of a read that held more than one answer.
    private let pending: Mutex<LineBuffer>

    public init(descriptor: Int32, timeoutMilliseconds: Int32 = 125_000, answerBytes: Int = ControlClient.defaultAnswerBytes) {
        self.descriptor = descriptor
        self.timeoutMilliseconds = timeoutMilliseconds
        pending = Mutex(LineBuffer(limit: answerBytes))
    }

    /// Connects to the service's socket.
    public static func connect(to path: String) throws -> Self {
        Self(descriptor: try ConsoleSocket.connect(to: path))
    }

    /// A connected pair of local sockets: a client, and the descriptor to give `ControlConnection.serve(_:)`.
    public static func connectedPair() throws -> (client: ControlClient, server: Int32) {
        guard let pair = ConsoleSocket.streamPair(bufferBytes: 64 * 1_024) else { throw ControlClientError.system(errno) }
        return (Self(descriptor: pair.first), pair.second)
    }

    /// Sends `line` as it is, then a newline.
    public func send(_ line: Data) throws {
        try ConsoleSocket.writeAll(descriptor, Array(line) + [UInt8(ascii: "\n")], stallMilliseconds: timeoutMilliseconds)
    }

    /// The next answer; nil when the service closed the connection. An answer already read with the one before is returned
    /// without reading.
    public func receive() throws -> ControlAnswer? {
        let descriptor = self.descriptor
        let timeout = timeoutMilliseconds
        let read = pending.withLock { buffer in
            LineIO.readLine(from: descriptor, into: &buffer, readBytes: 4_096, timeoutMilliseconds: timeout)
        }
        switch read {
        case .line(let bytes): return try ControlAnswer(line: Data(bytes))
        case .closed: return nil
        case .timedOut: throw ControlClientError.timedOut
        case .tooLong: throw ControlClientError.answerTooLong
        case .failed(let code): throw ControlClientError.system(code)
        }
    }

    /// Sends a request without waiting for its answer, so that several can be sent before the first answer is read.
    public func request(_ method: String, id: Int = 1, params: [String: RPCValue] = [:]) throws {
        var members: [String: Any] = [:]
        for (key, value) in params {
            switch value {
            case .string(let text): members[key] = text
            case .bool(let flag): members[key] = flag
            }
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": members]
        try send(try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
    }

    /// Sends a request and returns its answer; an answer to another request is refused, not taken for this one.
    public func call(_ method: String, id: Int = 1, params: [String: RPCValue] = [:]) throws -> ControlAnswer {
        try request(method, id: id, params: params)
        guard let answer = try receive() else { throw ControlClientError.closed }
        guard answer.id == id || answer.id == nil else { throw ControlClientError.malformedAnswer }
        return answer
    }

    public func close() { ConsoleSocket.close(descriptor) }
}
