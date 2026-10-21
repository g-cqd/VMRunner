import Foundation

/// The BSD socket calls the I/O shell makes, each wrapped once so the `unsafe` pointer plumbing lives here and
/// nowhere else. Every function is non-blocking-aware: it returns a ``HostIOResult`` or an `errno`, never throws.
enum SocketCalls {
    // MARK: Creation and options

    /// Raises the soft limit on open descriptors toward `wanted` (never above the hard limit) and returns the limit now
    /// in force. Every flow holds a host socket, and a GUI process starts with only 256. Process-wide; harmless if the
    /// limit is already high enough.
    @discardableResult
    static func raiseDescriptorLimit(to wanted: rlim_t = 10_240) -> rlim_t {
        var limit = rlimit()
        // `getrlimit` and `setrlimit` read and write one `rlimit` struct.
        guard unsafe getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        let target = min(wanted, limit.rlim_max)
        if limit.rlim_cur < target {
            limit.rlim_cur = target
            _ = unsafe setrlimit(RLIMIT_NOFILE, &limit)
            _ = unsafe getrlimit(RLIMIT_NOFILE, &limit)
        }
        return limit.rlim_cur
    }

    /// A connected pair of `AF_UNIX` datagram sockets, both non-blocking, close-on-exec and with `bufferSize`-byte
    /// send buffers and four times that for receive (Virtualization.framework asks for at least double).
    static func datagramPair(bufferSize: Int) -> (guestSide: Int32, hostSide: Int32)? {
        var descriptors: [Int32] = [-1, -1]
        // `socketpair` fills exactly two descriptors.
        guard unsafe socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else { return nil }
        for descriptor in descriptors {
            setBufferSizes(descriptor, send: bufferSize, receive: bufferSize * 4)
            _ = setCloseOnExec(descriptor)
        }
        guard setNonBlocking(descriptors[1]) else {
            close(descriptors[0])
            close(descriptors[1])
            return nil
        }
        return (descriptors[0], descriptors[1])
    }

    /// A new non-blocking socket with `SIGPIPE` disabled, or `nil` with `errno` set.
    static func makeSocket(type: Int32, protocolNumber: Int32 = 0) -> Int32? {
        let descriptor = socket(AF_INET, type, protocolNumber)
        guard descriptor >= 0 else { return nil }
        guard setNonBlocking(descriptor), setCloseOnExec(descriptor), setFlag(descriptor, SOL_SOCKET, SO_NOSIGPIPE) else {
            let failure = errno
            close(descriptor)
            errno = failure
            return nil
        }
        return descriptor
    }

    static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    @discardableResult
    static func setFlag(_ descriptor: Int32, _ level: Int32, _ option: Int32) -> Bool {
        var enabled: Int32 = 1
        // `setsockopt` reads `size` bytes from the Int32 on the stack.
        return unsafe setsockopt(descriptor, level, option, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func setBufferSizes(_ descriptor: Int32, send: Int, receive: Int) {
        var sendSize = Int32(clamping: send)
        var receiveSize = Int32(clamping: receive)
        let size = socklen_t(MemoryLayout<Int32>.size)
        // Both calls read one Int32 from the stack.
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &sendSize, size)
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveSize, size)
    }

    // MARK: Connecting

    /// Starts connecting `descriptor` to `address:port`. Returns `0` (connected), `EINPROGRESS`, or another `errno`.
    static func connect(_ descriptor: Int32, address: UInt32, port: UInt16) -> Int32 {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr = in_addr(s_addr: address.bigEndian)
        let result = withUnsafePointer(to: &destination) { pointer in
            // `sockaddr_in` is layout-compatible with `sockaddr` for the length passed.
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    /// The pending error of a socket whose non-blocking connect finished (`SO_ERROR`), `0` for success.
    static func pendingError(_ descriptor: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        // `getsockopt` writes one Int32 into `value`.
        guard unsafe getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &value, &length) == 0 else { return errno }
        return value
    }

    // MARK: Transfer

    static func send(_ descriptor: Int32, _ bytes: ByteView) -> HostIOResult {
        guard !bytes.isEmpty else { return .wouldBlock }
        return unsafe bytes.withUnsafeBytes { raw in
            transfer { unsafe Darwin.send(descriptor, raw.baseAddress, raw.count, 0) }
        }
    }

    /// Reads into `buffer`. A zero-length result is reported as `.endOfStream`; datagram callers treat it as empty.
    static func receive(_ descriptor: Int32, into buffer: MutableByteView) -> HostIOResult {
        guard !buffer.isEmpty else { return .wouldBlock }
        return unsafe buffer.withUnsafeMutableBytes { raw in
            transfer(zeroIsEnd: true) { unsafe Darwin.recv(descriptor, raw.baseAddress, raw.count, 0) }
        }
    }

    private static func transfer(zeroIsEnd: Bool = false, _ call: () -> Int) -> HostIOResult {
        while true {
            let count = call()
            if count > 0 { return .transferred(count) }
            if count == 0 { return zeroIsEnd ? .endOfStream : .wouldBlock }
            switch errno {
            case EINTR: continue
            case EAGAIN, ENOBUFS: return .wouldBlock
            default: return .failed(errno)
            }
        }
    }

    // MARK: Closing

    static func shutdownWrite(_ descriptor: Int32) {
        _ = shutdown(descriptor, SHUT_WR)
    }

    /// Closes the descriptor; with `reset`, discards unsent data and makes the peer see a reset.
    static func close(_ descriptor: Int32, reset: Bool = false) {
        if reset {
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            // `setsockopt` reads one `linger` struct.
            _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        }
        _ = Darwin.close(descriptor)
    }

    /// For an ICMP datagram socket, the offset of the ICMP message inside a received buffer: macOS includes the IP
    /// header, so skip the number of bytes its header-length nibble announces.
    static func icmpMessageOffset(in received: ByteView) -> Int? {
        guard let first = received[0], first >> 4 == 4 else { return 0 }
        let length = Int(first & 0x0F) * 4
        return length >= IPv4Header.minimumLength && length < received.count ? length : nil
    }
}
