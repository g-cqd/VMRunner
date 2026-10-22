import Foundation

/// Why a console could not be served or used. Messages are written for the person running the command.
public enum ConsoleError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The socket path does not fit `sockaddr_un.sun_path`.
    case pathTooLong(path: String, limit: Int)
    case pathNotAbsolute(String)
    /// The directory the socket would live in is not private to this user.
    case directoryNotPrivate(path: String, reason: String)
    /// Something that is not a socket is in the way.
    case notASocket(String)
    /// A socket this user does not own is in the way.
    case notOwnedByUser(String)
    /// Another process is serving the path.
    case socketInUse(String)
    /// A system call failed.
    case system(call: String, code: Int32)
    /// Nothing is serving the path.
    case notServed(String)
    /// The console already has a client.
    case busy
    /// The console ended; `lastOutput` is the tail of what it sent.
    case closed(lastOutput: String)
    /// A step took longer than allowed; `tail` is the tail of what the console sent meanwhile.
    case timedOut(waitingFor: String, tail: String)
    case loginFailed(String)
    case outputTooLarge(limit: Int)
    case invalidCommand(String)

    public var description: String {
        switch self {
        case .pathTooLong(let path, let limit):
            "the socket path is \(path.utf8.count) bytes; a local socket path holds at most \(limit): \(path)"
        case .pathNotAbsolute(let path): "the socket path must be absolute: \(path)"
        case .directoryNotPrivate(let path, let reason): "the directory \(path) is not private to this user: \(reason)"
        case .notASocket(let path): "\(path) exists and is not a socket"
        case .notOwnedByUser(let path): "\(path) is a socket that belongs to another user"
        case .socketInUse(let path): "another process is serving \(path)"
        case .system(let call, let code): "\(call) failed: \(unsafe String(cString: strerror(code))) (errno \(code))"
        case .notServed(let path): "nothing is serving the console socket \(path)"
        case .busy: "the console already has a client"
        case .closed(let lastOutput):
            lastOutput.isEmpty ? "the console closed" : "the console closed; the last output was: \(lastOutput)"
        case .timedOut(let waitingFor, let tail):
            tail.isEmpty
                ? "timed out waiting for \(waitingFor); the console sent nothing meanwhile"
                : "timed out waiting for \(waitingFor); the last output was: \(tail)"
        case .loginFailed(let reason): "login failed: \(reason)"
        case .outputTooLarge(let limit): "the command printed more than \(limit) bytes"
        case .invalidCommand(let reason): "the command cannot be sent: \(reason)"
        }
    }
}
