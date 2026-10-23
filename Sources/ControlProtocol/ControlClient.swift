public import Foundation
import GuestConsole

/// Why a client call failed.
public enum ControlClientError: Error, Equatable, Sendable {
    case closed
    case timedOut
    case answerTooLong
    case malformedAnswer
    case system(Int32)
}

/// An answer as the client reads it.
public struct ControlAnswer: Equatable, Sendable {
    public let id: Int?
    public let errorCode: Int?
    public let errorMessage: String?
    /// The `result` member as JSON with sorted keys; nil for an error.
    public let result: Data?

    init(line: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["jsonrpc"] as? String == "2.0"
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

/// A minimal blocking client of the control service: one request, then its answer. The tests drive the protocol end to end
/// with it; a command-line client can build on it.
public struct ControlClient: Sendable {
    public let descriptor: Int32
    /// How long a call waits for the service to take the request and to answer: longer than the service's own 120 s limit
    /// for an answer, so a slow start is answered rather than abandoned.
    public var timeoutMilliseconds: Int32 = 125_000

    public init(descriptor: Int32) { self.descriptor = descriptor }

    /// Connects to the service's socket.
    public static func connect(to path: String) throws -> Self {
        Self(descriptor: try ConsoleSocket.connect(to: path))
    }

    /// A connected pair of local sockets: a client, and the descriptor to give `ControlConnection.serve(_:)`.
    public static func connectedPair() throws -> (client: Self, server: Int32) {
        guard let pair = ConsoleSocket.streamPair(bufferBytes: 64 * 1_024) else { throw ControlClientError.system(errno) }
        return (Self(descriptor: pair.first), pair.second)
    }

    /// Sends `line` as it is, then a newline.
    public func send(_ line: Data) throws {
        try ConsoleSocket.writeAll(descriptor, Array(line) + [UInt8(ascii: "\n")], stallMilliseconds: timeoutMilliseconds)
    }

    /// The next answer; nil when the service closed the connection.
    public func receive() throws -> ControlAnswer? {
        var buffer = LineBuffer(limit: 1 << 20)
        switch LineIO.readLine(from: descriptor, into: &buffer, readBytes: 4_096, timeoutMilliseconds: timeoutMilliseconds) {
        case .line(let bytes): return try ControlAnswer(line: Data(bytes))
        case .closed: return nil
        case .timedOut: throw ControlClientError.timedOut
        case .tooLong: throw ControlClientError.answerTooLong
        case .failed(let code): throw ControlClientError.system(code)
        }
    }

    /// Sends a request and returns its answer.
    public func call(_ method: String, id: Int = 1, params: [String: RPCValue] = [:]) throws -> ControlAnswer {
        var members: [String: Any] = [:]
        for (key, value) in params {
            switch value {
            case .string(let text): members[key] = text
            case .bool(let flag): members[key] = flag
            }
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": members]
        try send(try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
        guard let answer = try receive() else { throw ControlClientError.closed }
        return answer
    }

    public func close() { ConsoleSocket.close(descriptor) }
}
