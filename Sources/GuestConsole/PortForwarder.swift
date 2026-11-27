import Foundation
import Synchronization

/// Serves one guest port on a local socket of this Mac: every connection a process of this user makes to the socket is
/// joined to a new connection into the guest, and bytes are relayed both ways until both sides have closed.
///
/// Nothing leaves this Mac: the socket is a file in a private folder (mode 0600 in a 0700 folder), a peer of another user
/// is refused even if it got that far, and the guest side is whatever ``Channel`` the owner opens (a vsock connection for
/// a virtual machine). The forwarder makes no network listener of any kind.
public final class PortForwarder: Sendable {
    /// One connection into the guest: its descriptor, and what releases it once the relay is done (the framework object
    /// that owns the descriptor, for instance).
    public struct Channel: Sendable {
        public let descriptor: Int32
        public let release: @Sendable () -> Void

        public init(descriptor: Int32, release: @escaping @Sendable () -> Void) {
            self.descriptor = descriptor
            self.release = release
        }
    }

    /// The most connections relayed at once; further ones are closed as they arrive.
    public static let maxConnections = 16
    private static let chunk = 64 * 1024

    public let socketPath: String
    private let listener: Int32
    private let identity: SocketIdentity
    private let open: @Sendable () async -> Channel?
    /// Written once to wake the accept loop for ``stop()``.
    private let wake: (read: Int32, write: Int32)
    private let state = Mutex(State())

    private struct State {
        var isStopped = false
        var started = false
        /// The descriptors of the relays running now, shut down by ``stop()``.
        var relayed: Set<Int32> = []
    }

    /// Binds `socketPath` (its folder must exist and be private). Nothing is accepted until ``start()``.
    ///
    /// - Parameters:
    ///   - socketPath: the socket's path, in a folder that exists and only this user can enter.
    ///   - open: opens a connection into the guest, or returns nil when it cannot (the client is then closed).
    /// - Throws: `ConsoleError` when the folder is not private, the path is too long or taken, or a system call fails.
    public init(socketPath: String, open: @escaping @Sendable () async -> Channel?) throws {
        var pipeEnds: [Int32] = [-1, -1]
        // `pipe` fills exactly two descriptors.
        guard unsafe pipe(&pipeEnds) == 0 else { throw ConsoleError.system(call: "pipe", code: errno) }
        for end in pipeEnds { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        do {
            (listener, identity) = try ConsoleSocket.listen(at: socketPath)
        } catch {
            pipeEnds.forEach(ConsoleSocket.close)
            throw error
        }
        self.socketPath = socketPath
        self.open = open
        wake = (pipeEnds[0], pipeEnds[1])
    }

    deinit { stop() }

    /// Starts accepting connections on a thread of its own.
    public func start() {
        let shouldStart = state.withLock { state in
            guard !state.started, !state.isStopped else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "vmrunner.port-forwarder"
        thread.start()
    }

    /// Stops accepting, shuts down the relays running now, and removes the socket. Idempotent.
    public func stop() {
        let (wasStarted, open) = state.withLock { state -> (Bool, Set<Int32>) in
            guard !state.isStopped else { return (true, []) }
            state.isStopped = true
            return (state.started, state.relayed)
        }
        for descriptor in open { _ = shutdown(descriptor, SHUT_RDWR) }
        if wasStarted {
            var byte: UInt8 = 1
            // `write` reads one byte.
            _ = unsafe write(wake.write, &byte, 1)
        } else {
            closeListener()
        }
    }

    private var stopped: Bool { state.withLock { $0.isStopped } }

    private func closeListener() {
        ConsoleSocket.removeSocket(at: socketPath, identity: identity)
        ConsoleSocket.close(listener)
        ConsoleSocket.close(wake.read)
        ConsoleSocket.close(wake.write)
    }

    // MARK: Accepting

    private func acceptLoop() {
        defer { closeListener() }
        var descriptors = [
            pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
        ]
        while !stopped {
            // `poll` reads and writes the two entries.
            let ready = unsafe poll(&descriptors, nfds_t(descriptors.count), -1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, descriptors[1].revents == 0, !stopped else { return }
            while let client = ConsoleSocket.accept(listener) { admit(client) }
        }
    }

    private func admit(_ client: Int32) {
        let admitted =
            ConsoleSocket.peerIsCurrentUser(client)
            && state.withLock { state in
                guard !state.isStopped, state.relayed.count < 2 * Self.maxConnections else { return false }
                state.relayed.insert(client)
                return true
            }
        guard admitted else {
            ConsoleSocket.close(client)
            return
        }
        let open = open
        Task.detached { [self] in
            guard let channel = await open() else {
                finish(client)
                return
            }
            guard register(channel.descriptor) else {
                finish(client)
                ConsoleSocket.close(channel.descriptor)
                channel.release()
                return
            }
            relay(client: client, channel: channel)
        }
    }

    private func register(_ descriptor: Int32) -> Bool {
        state.withLock { state in
            guard !state.isStopped else { return false }
            state.relayed.insert(descriptor)
            return true
        }
    }

    private func finish(_ descriptor: Int32) {
        _ = state.withLock { $0.relayed.remove(descriptor) }
        ConsoleSocket.close(descriptor)
    }

    // MARK: Relaying

    /// Two threads, one per direction, so a side that stops reading never blocks the other direction. Each direction ends
    /// at its source's end of stream (or an error) and passes the end on with a half-close; the descriptors are closed and
    /// the channel released once both directions have ended.
    private func relay(client: Int32, channel: Channel) {
        for descriptor in [client, channel.descriptor] { Self.makeBlocking(descriptor) }
        let remaining = Countdown(2) { [self] in
            finish(client)
            finish(channel.descriptor)
            channel.release()
        }
        for (source, destination) in [(client, channel.descriptor), (channel.descriptor, client)] {
            let thread = Thread {
                Self.pump(from: source, to: destination)
                _ = shutdown(destination, SHUT_WR)
                remaining.tick()
            }
            thread.name = "vmrunner.port-forwarder.relay"
            thread.start()
        }
    }

    private static func makeBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
        var enabled: Int32 = 1
        // `setsockopt` reads one Int32 from the stack.
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Copies `source` to `destination` until the source ends or either side fails.
    static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            // `read` writes at most `buffer.count` bytes into the buffer.
            let count = buffer.withUnsafeMutableBytes { unsafe Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            var offset = 0
            while offset < count {
                // `write` reads `count - offset` bytes of the buffer from `offset`.
                let written = buffer.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return -1 }
                    return unsafe Darwin.write(destination, base + offset, count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

/// Runs `action` once, on the `count`-th ``tick()``.
private final class Countdown: Sendable {
    private let remaining: Mutex<Int>
    private let action: @Sendable () -> Void

    init(_ count: Int, action: @escaping @Sendable () -> Void) {
        remaining = Mutex(count)
        self.action = action
    }

    func tick() {
        let done = remaining.withLock { remaining in
            remaining -= 1
            return remaining == 0
        }
        if done { action() }
    }
}
