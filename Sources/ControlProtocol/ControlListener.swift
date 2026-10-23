import Foundation
import GuestConsole
import Synchronization

/// Counts the connections being served and refuses one past the limit.
public final class ConnectionLimiter: Sendable {
    public let limit: Int
    private let active = Mutex(0)

    public init(limit: Int) { self.limit = limit }

    /// Takes a place; false when every place is taken.
    public func acquire() -> Bool {
        active.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    /// Gives a place back.
    public func release() { active.withLock { $0 = max(0, $0 - 1) } }

    /// The places taken now.
    public var count: Int { active.withLock { $0 } }
}

/// Listens on the control socket (ADR-0056) and serves each client on a task of its own, at most `limits.connections` at once;
/// a client past that is closed at once. The socket follows the console's rules (ADR-0052): created 0600 in a directory that
/// must be private to this user, refused when the path is too long or a live process serves it, and a stale socket of this
/// user removed first.
public final class ControlListener: Sendable {
    public let path: String
    private let stopFlag = StopFlag()
    private let finished: AsyncStream<Void>

    /// Binds `path` and starts accepting on a thread of its own.
    public init(path: String, connection: ControlConnection, limits: ControlLimits = ControlLimits()) throws {
        let bound = try ConsoleSocket.listen(at: path)
        self.path = path
        let (finished, done) = AsyncStream.makeStream(of: Void.self)
        self.finished = finished
        let limiter = ConnectionLimiter(limit: limits.connections)
        let flag = stopFlag
        let thread = Thread {
            Self.acceptLoop(listener: bound.descriptor, connection: connection, limiter: limiter, flag: flag)
            ConsoleSocket.close(bound.descriptor)
            ConsoleSocket.removeSocket(at: path, identity: bound.identity)
            done.finish()
        }
        thread.name = "ControlProtocol.ControlListener"
        thread.start()
    }

    deinit { stopFlag.set() }

    /// Stops accepting: the loop notices within a tenth of a second, then closes and removes the socket. A client already
    /// connected gets no answer to a request it sends from now on (its connection closes); one being run goes on.
    public func stop() { stopFlag.set() }

    /// Returns once the loop has ended and the socket file is gone. One caller at a time.
    public func waitUntilStopped() async {
        for await _ in finished {}
    }

    private static func acceptLoop(listener: Int32, connection: ControlConnection, limiter: ConnectionLimiter, flag: StopFlag) {
        while !flag.isSet {
            guard ConsoleSocket.wait(listener, milliseconds: 100) else { continue }
            guard let client = ConsoleSocket.accept(listener) else {
                // Readable but nothing accepted (out of descriptors): pause rather than spin.
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard limiter.acquire() else {
                ConsoleSocket.close(client)
                continue
            }
            Task.detached {
                await connection.serve(client, while: { !flag.isSet })
                limiter.release()
            }
        }
    }
}

/// A flag one thread sets and another reads.
final class StopFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() { value.withLock { $0 = true } }
}
