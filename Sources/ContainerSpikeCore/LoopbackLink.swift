public import Foundation
import Synchronization

/// Why the loopback link could not be made.
public enum LoopbackError: Error, Equatable, Sendable {
    /// A system call failed with this `errno`.
    case systemCall(Int32)
}

/// A pair of connected datagram sockets standing in for the user-mode network stack: the guest's network device gets one
/// end, a reader thread collects the frames that arrive on the other. Each datagram is one Ethernet frame, as with the
/// stack's own link, so swapping the real stack in means replacing this reader and nothing on the guest side.
///
/// The reader runs on its own thread and closes the host end itself when it stops, so no descriptor is closed while it is
/// still being read.
public final class LoopbackLink: Sendable {
    /// Largest frame read: the stack's maximum MTU plus an Ethernet header.
    private static let maximumFrame = 65_535 + 14

    /// The guest's end. It owns the descriptor and closes it when released, which is what a device attachment does too.
    public let guestHandle: FileHandle
    /// The frames the guest sent, in order; finishes when ``stop()`` is called or the link is released.
    public let frames: AsyncStream<[UInt8]>
    private let stopRequested = StopFlag()

    /// Makes the pair and starts reading.
    ///
    /// - Throws: ``LoopbackError``.
    public init() throws(LoopbackError) {
        var descriptors: [Int32] = [-1, -1]
        // `socketpair` fills exactly two descriptors.
        guard unsafe socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else { throw .systemCall(errno) }
        let (guest, host) = (descriptors[0], descriptors[1])
        for descriptor in descriptors {
            Self.prepare(descriptor)
        }
        guestHandle = FileHandle(fileDescriptor: guest, closeOnDealloc: true)
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(256))
        frames = stream
        let flag = stopRequested
        continuation.onTermination = { _ in flag.raise() }
        let thread = Thread { Self.read(host, into: continuation, until: flag) }
        thread.name = "ContainerSpike.LoopbackLink"
        thread.start()
    }

    deinit {
        stopRequested.raise()
    }

    /// Asks the reader to finish: it closes the host end and ends ``frames``. Idempotent.
    public func stop() {
        stopRequested.raise()
    }

    /// Close-on-exec, and buffers large enough for a frame: the default datagram limit of a local socket is 2 KiB, and the
    /// virtualization framework asks for at least double the largest frame. The sizes are the stack's own.
    private static func prepare(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var send = Int32(1 << 20)
        var receive = Int32(4 << 20)
        let size = socklen_t(MemoryLayout<Int32>.size)
        // Each call reads one Int32 from the stack.
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &send, size)
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receive, size)
    }

    /// Reads datagrams from `descriptor` until `flag` is raised, polling every 100 ms so a raised flag is noticed.
    private static func read(_ descriptor: Int32, into continuation: AsyncStream<[UInt8]>.Continuation, until flag: StopFlag) {
        var buffer = [UInt8](repeating: 0, count: maximumFrame)
        while !flag.isRaised {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // `poll` reads and writes one `pollfd`.
            let ready = unsafe poll(&request, 1, 100)
            if ready < 0 && errno != EINTR { break }
            guard ready > 0 else { continue }
            // `recv` writes at most `buffer.count` bytes into the array's storage.
            let count = buffer.withUnsafeMutableBytes { unsafe recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno != EINTR && errno != EAGAIN { break }
            if count > 0 { continuation.yield(Array(buffer[..<count])) }
        }
        close(descriptor)
        continuation.finish()
    }
}

/// A flag one side raises and the other polls.
private final class StopFlag: Sendable {
    private let raised = Mutex(false)

    var isRaised: Bool { raised.withLock { $0 } }

    func raise() {
        raised.withLock { $0 = true }
    }
}
