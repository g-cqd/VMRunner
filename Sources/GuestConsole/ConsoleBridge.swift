public import Foundation
import Synchronization

/// Serves a guest's serial console on a private local socket.
///
/// The guest side is a connected stream socket whose other end belongs to the guest's serial port
/// (`VZFileHandleSerialPortAttachment`). The bridge listens on a Unix domain socket, accepts **one** client at a time and
/// copies bytes both ways on a single thread:
///
/// - The socket is created with mode 0600 inside a directory that must be private to the user (0700, owned by the user), and
///   a client must run as the user. A second connection gets one line (``busyMessage``) and is closed.
/// - The last ``replayCapacity`` bytes the guest printed are kept and replayed to each new client, so a client that arrives
///   after the boot still sees the prompt.
/// - A missing or slow client never holds the guest back: guest output is stored in bounded buffers that drop their oldest
///   bytes (counted in ``Statistics``): the replay buffer, and a queue of ``clientQueueCapacity`` bytes for a client that
///   reads more slowly than the guest prints. Input toward the guest is bounded too, and when the guest stops reading it the
///   client is simply not read from.
/// - The bridge ends, closing the client and removing the socket, when ``stop()`` is called or the guest side closes.
public final class ConsoleBridge: Sendable {
    /// How much recent guest output a new client is shown.
    public static let replayCapacity = 64 * 1024
    /// How much output a connected client may lag behind by before the oldest output is dropped.
    public static let clientQueueCapacity = 1 << 20
    /// Capacity of each socket buffer of the guest pair, and of a client's socket.
    public static let pairBufferBytes = 256 * 1024
    /// The longest socket path in bytes (`sockaddr_un.sun_path` less its terminating NUL).
    public static var socketPathLimit: Int { ConsoleSocket.pathLimit }
    /// What a refused second client receives before it is closed.
    public static let busyMessage = "vmr-console: busy: another client is attached\n"

    /// What the bridge has done so far.
    public struct Statistics: Equatable, Sendable {
        /// Bytes the guest printed, and bytes the clients typed that reached the guest.
        public var guestBytesRead = 0
        public var guestBytesWritten = 0
        /// Bytes the clients sent, and bytes delivered to a client.
        public var clientBytesRead = 0
        public var clientBytesWritten = 0
        /// Guest output a connected client did not read in time and that was dropped, oldest first.
        public var droppedToClient = 0
        /// Guest output that left the replay buffer because newer output pushed it out (no client needed to be slow).
        public var replayDiscarded = 0
        public var clientsAccepted = 0
        public var clientsRefused = 0

        public init() {}
    }

    /// The two ends of a connected stream socket: `guest` goes to the serial port, `host` to the bridge.
    public struct GuestPair: Sendable {
        public let guest: Int32
        public let host: Int32

        /// The guest end as the two file handles a serial port attachment takes, one to read from and one to write to. Each
        /// owns a descriptor and closes it when released, so `guest` belongs to them from here on: do not close it.
        /// On a failure `guest` is closed here and `host` is left to the caller.
        public func guestHandles() throws -> (reading: FileHandle, writing: FileHandle) {
            let duplicate = dup(guest)
            guard duplicate >= 0 else {
                let code = errno
                ConsoleSocket.close(guest)
                throw ConsoleError.system(call: "dup", code: code)
            }
            return (FileHandle(fileDescriptor: duplicate, closeOnDealloc: true), FileHandle(fileDescriptor: guest, closeOnDealloc: true))
        }
    }

    fileprivate enum Lifecycle { case ready, running, stopped }

    fileprivate struct State {
        var lifecycle = Lifecycle.ready
        var stopRequested = false
        var statistics = Statistics()
    }

    /// What the loop thread and the callers share.
    fileprivate final class Control: Sendable {
        let state = Mutex(State())
        let queue: ReadinessQueue
        let finished = FinishLatch()

        init(queue: ReadinessQueue) {
            self.queue = queue
        }

        var stopRequested: Bool { state.withLock(\.stopRequested) }
    }

    /// The socket clients connect to.
    public let socketPath: String
    private let control: Control
    private let guest: Int32
    private let listener: Int32
    private let identity: SocketIdentity

    /// Creates the guest socket pair for a console: give `guest` to the serial port, `host` to ``init(guestDescriptor:socketPath:)``.
    public static func makeGuestPair() throws -> GuestPair {
        guard let pair = ConsoleSocket.streamPair(bufferBytes: pairBufferBytes) else {
            throw ConsoleError.system(call: "socketpair", code: errno)
        }
        return GuestPair(guest: pair.first, host: pair.second)
    }

    /// Makes `path` a directory only this user can enter, creating it (mode 0700) when it is missing. An existing directory
    /// is checked, not changed: it must belong to this user and be closed to everyone else.
    public static func makePrivateDirectory(at path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(
                    atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch {
                throw ConsoleError.directoryNotPrivate(path: path, reason: "it cannot be created: \(error.localizedDescription)")
            }
        }
        try ConsoleSocket.requirePrivateDirectory(path)
    }

    /// Binds `socketPath` and prepares to bridge `guestDescriptor`, the host end of a ``GuestPair``. Nothing runs until ``start()``.
    ///
    /// The bridge owns `guestDescriptor` once this returns; when it throws the caller still owns it. Refuses a path longer than
    /// a local socket path allows, a path that holds something other than a socket, a socket another process serves or another
    /// user owns, and a parent directory that is not private. A stale socket of this user is removed.
    public init(guestDescriptor: Int32, socketPath: String) throws {
        guard ConsoleSocket.prepare(guestDescriptor, nonBlocking: true) else {
            throw ConsoleError.system(call: "fcntl", code: errno)
        }
        guard let queue = ReadinessQueue() else { throw ConsoleError.system(call: "kqueue", code: errno) }
        let bound = try ConsoleSocket.listen(at: socketPath)
        self.socketPath = socketPath
        control = Control(queue: queue)
        guest = guestDescriptor
        listener = bound.descriptor
        identity = bound.identity
    }

    deinit {
        let wasRunning = control.state.withLock { $0.lifecycle == .running }
        if wasRunning {
            // The loop thread holds the descriptors and closes them when it ends.
            requestStop()
        } else {
            releaseUnstarted()
        }
    }

    /// Starts serving on a thread of its own. Does nothing when already started or stopped.
    public func start() {
        let shouldStart = control.state.withLock { state -> Bool in
            guard state.lifecycle == .ready else { return false }
            state.lifecycle = .running
            return true
        }
        guard shouldStart else { return }
        let inputs = (control: control, guest: guest, listener: listener, path: socketPath, identity: identity)
        let thread = Thread {
            let loop = ConsoleLoop(
                control: inputs.control, guest: inputs.guest, listener: inputs.listener, path: inputs.path, identity: inputs.identity)
            loop.run()
            inputs.control.state.withLock { $0.lifecycle = .stopped }
            inputs.control.finished.open()
        }
        thread.name = "GuestConsole.ConsoleBridge"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Ends the bridge: the client sees the end of the stream, the socket is removed and the guest side is closed. Returns at once;
    /// ``waitUntilFinished()`` says when it is done. Idempotent.
    public func stop() {
        let wasReady = control.state.withLock { $0.lifecycle == .ready }
        if wasReady {
            releaseUnstarted()
        } else {
            requestStop()
        }
    }

    /// Returns once the bridge has ended (stopped, or the guest side closed) and released everything. Any number of callers may wait.
    public func waitUntilFinished() async {
        await control.finished.wait()
    }

    /// A snapshot of the counters, refreshed after every wake of the loop thread.
    public var statistics: Statistics { control.state.withLock(\.statistics) }

    private func requestStop() {
        control.state.withLock { $0.stopRequested = true }
        control.queue.wake()
    }

    /// Closes what an unstarted bridge holds.
    private func releaseUnstarted() {
        let release = control.state.withLock { state -> Bool in
            guard state.lifecycle == .ready else { return false }
            state.lifecycle = .stopped
            return true
        }
        guard release else { return }
        ConsoleSocket.close(listener)
        ConsoleSocket.close(guest)
        ConsoleSocket.removeSocket(at: socketPath, identity: identity)
        control.finished.open()
    }
}

/// One-way broadcast: `open()` releases every waiter, now and later.
private final class FinishLatch: Sendable {
    fileprivate struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func open() {
        let released = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in released { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// The bridge's event loop. Runs on one thread, which owns every descriptor and buffer, so none of this needs a lock.
private final class ConsoleLoop {
    private struct Interests: Equatable {
        var clientRead = false
        var clientWrite = false
        var guestWrite = false
    }

    private static let chunk = 16 * 1024
    private static let readsPerWake = 16

    private let control: ConsoleBridge.Control
    private let queue: ReadinessQueue
    private let guest: Int32
    private let listener: Int32
    private let path: String
    private let identity: SocketIdentity
    private var client: Int32 = -1
    private var replay = ByteFIFO(capacity: ConsoleBridge.replayCapacity)
    private var toClient = ByteFIFO(capacity: ConsoleBridge.clientQueueCapacity)
    private var toGuest = ByteFIFO(capacity: ConsoleBridge.replayCapacity)
    private var scratch = [UInt8](repeating: 0, count: ConsoleLoop.chunk)
    private var interests = Interests()
    private var statistics = ConsoleBridge.Statistics()
    private var guestOpen = true

    init(control: ConsoleBridge.Control, guest: Int32, listener: Int32, path: String, identity: SocketIdentity) {
        self.control = control
        queue = control.queue
        self.guest = guest
        self.listener = listener
        self.path = path
        self.identity = identity
    }

    func run() {
        queue.watch(listener, writing: false, add: true)
        queue.watch(guest, writing: false, add: true)
        while guestOpen, !control.stopRequested {
            for event in queue.wait() {
                switch event.kind {
                case .wakeup: break
                case .readable: readable(event.descriptor)
                case .writable: writable(event.descriptor)
                }
            }
            updateInterests()
            publish()
        }
        shutDown()
    }

    // MARK: Events

    private func readable(_ descriptor: Int32) {
        if descriptor == listener {
            acceptClients()
        } else if descriptor == guest {
            pumpGuestOutput()
        } else if descriptor == client {
            pumpClientInput()
        }
    }

    private func writable(_ descriptor: Int32) {
        if descriptor == guest {
            flushToGuest()
        } else if descriptor == client {
            flushToClient()
        }
    }

    private func acceptClients() {
        while let accepted = ConsoleSocket.accept(listener) {
            guard ConsoleSocket.peerIsCurrentUser(accepted) else {
                statistics.clientsRefused += 1
                ConsoleSocket.close(accepted)
                continue
            }
            guard client < 0 else {
                statistics.clientsRefused += 1
                // The message is tiny and the new socket's buffer is empty, so one write takes all of it.
                _ = Array(ConsoleBridge.busyMessage.utf8).withUnsafeBytes { unsafe ConsoleSocket.write(accepted, $0) }
                ConsoleSocket.close(accepted)
                continue
            }
            client = accepted
            ConsoleSocket.setBufferSizes(accepted, bytes: ConsoleBridge.pairBufferBytes)
            statistics.clientsAccepted += 1
            toClient.removeAll()
            toClient.append(replay.contents()[...])
            flushToClient()
        }
    }

    private func pumpGuestOutput() {
        var reads = 0
        while reads < Self.readsPerWake {
            reads += 1
            switch ConsoleSocket.read(guest, into: &scratch) {
            case .transferred(let count):
                let received = scratch[0..<count]
                statistics.guestBytesRead += count
                statistics.replayDiscarded += replay.appendDroppingOldest(received)
                if client >= 0 { statistics.droppedToClient += toClient.appendDroppingOldest(received) }
            case .wouldBlock:
                reads = Self.readsPerWake
            case .endOfStream, .failed:
                guestOpen = false
                reads = Self.readsPerWake
            }
        }
        if client >= 0 { flushToClient() }
    }

    private func pumpClientInput() {
        var reads = 0
        while reads < Self.readsPerWake, client >= 0, toGuest.free > 0 {
            reads += 1
            switch ConsoleSocket.read(client, into: &scratch, limit: toGuest.free) {
            case .transferred(let count):
                statistics.clientBytesRead += count
                toGuest.append(scratch[0..<count])
            case .wouldBlock:
                reads = Self.readsPerWake
            case .endOfStream, .failed:
                dropClient()
            }
        }
        flushToGuest()
    }

    private func flushToClient() {
        while client >= 0, !toClient.isEmpty {
            switch toClient.writeFront(to: client) {
            case .transferred(let count):
                toClient.discardFront(count)
                statistics.clientBytesWritten += count
            case .wouldBlock:
                return
            case .endOfStream, .failed:
                dropClient()
            }
        }
    }

    private func flushToGuest() {
        while guestOpen, !toGuest.isEmpty {
            switch toGuest.writeFront(to: guest) {
            case .transferred(let count):
                toGuest.discardFront(count)
                statistics.guestBytesWritten += count
            case .wouldBlock:
                return
            case .endOfStream, .failed:
                guestOpen = false
            }
        }
    }

    private func dropClient() {
        // Closing the descriptor removes its filters from the queue.
        ConsoleSocket.close(client)
        client = -1
        interests.clientRead = false
        interests.clientWrite = false
        toClient.removeAll()
    }

    // MARK: Bookkeeping

    /// Watches the client for input while the guest has room for it, and each side for writability while bytes wait for it.
    private func updateInterests() {
        let wanted = Interests(
            clientRead: client >= 0 && toGuest.free > 0, clientWrite: client >= 0 && !toClient.isEmpty, guestWrite: !toGuest.isEmpty)
        guard wanted != interests else { return }
        if client >= 0 {
            if wanted.clientRead != interests.clientRead { queue.watch(client, writing: false, add: wanted.clientRead) }
            if wanted.clientWrite != interests.clientWrite { queue.watch(client, writing: true, add: wanted.clientWrite) }
        }
        if wanted.guestWrite != interests.guestWrite { queue.watch(guest, writing: true, add: wanted.guestWrite) }
        interests = wanted
    }

    private func publish() {
        let snapshot = statistics
        control.state.withLock { $0.statistics = snapshot }
    }

    private func shutDown() {
        if client >= 0 {
            // Hand over what is waiting, giving a slow client a moment (at most a second), then it sees the end of the stream.
            var attempts = 0
            flushToClient()
            while client >= 0, !toClient.isEmpty, attempts < 10 {
                attempts += 1
                if ConsoleSocket.wait(client, forWriting: true, milliseconds: 100) { flushToClient() }
            }
            if client >= 0 { dropClient() }
        }
        ConsoleSocket.close(listener)
        ConsoleSocket.removeSocket(at: path, identity: identity)
        ConsoleSocket.close(guest)
        publish()
    }
}
