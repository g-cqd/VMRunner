import Foundation

/// What one non-blocking transfer did.
package enum TransferResult: Equatable, Sendable {
    case transferred(Int)
    case wouldBlock
    /// The peer closed (a read returned zero).
    case endOfStream
    case failed(Int32)
}

/// Who a listening socket is: its device and inode, so that the cleanup removes the socket it made and not a later one
/// somebody put in its place.
package struct SocketIdentity: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t
}

/// The socket calls the console makes, each wrapped once so the pointer plumbing lives here and nowhere else.
package enum ConsoleSocket {
    /// `sun_path` holds this many bytes including the terminating NUL.
    static var pathCapacity: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /// The longest socket path in bytes.
    static var pathLimit: Int { pathCapacity - 1 }

    // MARK: Descriptors

    static func prepare(_ descriptor: Int32, nonBlocking: Bool) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, descriptorFlags >= 0 else { return false }
        if nonBlocking, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0 { return false }
        guard fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { return false }
        var enabled: Int32 = 1
        // `setsockopt` reads one Int32 from the stack.
        return unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func setBufferSizes(_ descriptor: Int32, bytes: Int) {
        var size = Int32(clamping: bytes)
        let length = socklen_t(MemoryLayout<Int32>.size)
        // Both calls read one Int32 from the stack.
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, length)
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, length)
    }

    package static func close(_ descriptor: Int32) {
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    /// A connected pair of stream sockets, close-on-exec, with generous buffers: one end goes to the guest's serial
    /// port, the other to the bridge.
    package static func streamPair(bufferBytes: Int) -> (first: Int32, second: Int32)? {
        var descriptors: [Int32] = [-1, -1]
        // `socketpair` fills exactly two descriptors.
        guard unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }
        for descriptor in descriptors {
            setBufferSizes(descriptor, bytes: bufferBytes)
            guard prepare(descriptor, nonBlocking: false) else {
                close(descriptors[0])
                close(descriptors[1])
                return nil
            }
        }
        return (descriptors[0], descriptors[1])
    }

    // MARK: Transfer

    /// Reads at most `limit` bytes into `buffer`; the first `count` bytes are valid after `.transferred(count)`.
    package static func read(_ descriptor: Int32, into buffer: inout [UInt8], limit: Int? = nil) -> TransferResult {
        transfer(zeroIsEnd: true) {
            buffer.withUnsafeMutableBytes { raw in
                unsafe Darwin.read(descriptor, raw.baseAddress, min(raw.count, limit ?? raw.count))
            }
        }
    }

    static func write(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> TransferResult {
        guard unsafe !bytes.isEmpty else { return .wouldBlock }
        return transfer(zeroIsEnd: false) { unsafe Darwin.write(descriptor, bytes.baseAddress, bytes.count) }
    }

    /// Writes all of `bytes`, waiting up to `stallMilliseconds` each time the descriptor is full. A closed peer is
    /// ``ConsoleError/closed(lastOutput:)``.
    package static func writeAll(_ descriptor: Int32, _ bytes: [UInt8], stallMilliseconds: Int32) throws {
        var sent = 0
        while sent < bytes.count {
            switch bytes[sent...].withUnsafeBytes({ unsafe write(descriptor, $0) }) {
            case .transferred(let count):
                sent += count
            case .wouldBlock:
                guard wait(descriptor, forWriting: true, milliseconds: stallMilliseconds) else {
                    throw ConsoleError.timedOut(waitingFor: "the console to accept input", tail: "")
                }
            case .endOfStream:
                throw ConsoleError.closed(lastOutput: "")
            case .failed(let code):
                if code == EPIPE || code == ECONNRESET { throw ConsoleError.closed(lastOutput: "") }
                throw ConsoleError.system(call: "write", code: code)
            }
        }
    }

    private static func transfer(zeroIsEnd: Bool, _ call: () -> Int) -> TransferResult {
        while true {
            let count = call()
            if count > 0 { return .transferred(count) }
            if count == 0 { return zeroIsEnd ? .endOfStream : .wouldBlock }
            switch errno {
            case EINTR: continue
            case EAGAIN: return .wouldBlock
            case ECONNRESET: return zeroIsEnd ? .endOfStream : .failed(ECONNRESET)
            default: return .failed(errno)
            }
        }
    }

    // MARK: Addresses

    /// Runs `body` with a `sockaddr_un` for `path`, which must fit.
    private static func withAddress<Result>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) throws -> Result {
        let bytes = Array(path.utf8)
        guard bytes.count <= pathLimit else { throw ConsoleError.pathTooLong(path: path, limit: pathLimit) }
        guard !bytes.contains(0) else { throw ConsoleError.pathNotAbsolute(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // `sun_path` holds `pathCapacity` bytes; the path and its NUL fit (checked above), and the rest is zero.
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { unsafe raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            // `sockaddr_un` is layout-compatible with `sockaddr` for the length passed.
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in unsafe body(generic, length) }
        }
    }

    private static func bind(_ descriptor: Int32, to path: String) throws -> Int32 {
        try unsafe withAddress(path) { address, length in unsafe Darwin.bind(descriptor, address, length) }
    }

    private static func connect(_ descriptor: Int32, to path: String) throws -> Int32 {
        try unsafe withAddress(path) { address, length in unsafe Darwin.connect(descriptor, address, length) }
    }

    // MARK: Listening

    /// Binds and listens on `path`, creating the socket with mode 0600, and returns its descriptor (non-blocking) and identity.
    ///
    /// The directory must exist and be private (see ``requirePrivateDirectory(_:)``). A path that holds something else is
    /// refused; a socket of this user that nobody serves is a stale leftover and is removed.
    package static func listen(at path: String) throws -> (descriptor: Int32, identity: SocketIdentity) {
        guard path.hasPrefix("/") else { throw ConsoleError.pathNotAbsolute(path) }
        guard path.utf8.count <= pathLimit else { throw ConsoleError.pathTooLong(path: path, limit: pathLimit) }
        let directory = URL(filePath: path).deletingLastPathComponent().path
        try requirePrivateDirectory(directory)
        try removeStaleSocket(at: path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ConsoleError.system(call: "socket", code: errno) }
        guard prepare(descriptor, nonBlocking: true) else {
            let code = errno
            close(descriptor)
            throw ConsoleError.system(call: "fcntl", code: code)
        }
        do {
            let bound = try bind(descriptor, to: path)
            guard bound == 0 else { throw ConsoleError.system(call: "bind", code: errno) }
            // The directory is private, so nobody can reach the socket before this lands.
            guard unsafe chmod(path, 0o600) == 0 else { throw ConsoleError.system(call: "chmod", code: errno) }
            guard Darwin.listen(descriptor, 4) == 0 else { throw ConsoleError.system(call: "listen", code: errno) }
            var status = stat()
            guard unsafe lstat(path, &status) == 0 else { throw ConsoleError.system(call: "lstat", code: errno) }
            return (descriptor, SocketIdentity(device: status.st_dev, inode: status.st_ino))
        } catch {
            close(descriptor)
            _ = unsafe unlink(path)
            throw error
        }
    }

    /// Removes the socket at `path` when it is still the one identified by `identity`.
    package static func removeSocket(at path: String, identity: SocketIdentity) {
        var status = stat()
        guard unsafe lstat(path, &status) == 0, status.st_dev == identity.device, status.st_ino == identity.inode else { return }
        _ = unsafe unlink(path)
    }

    /// The directory must be a real directory (not a link), owned by this user and closed to group and others.
    static func requirePrivateDirectory(_ path: String) throws {
        var status = stat()
        guard unsafe lstat(path, &status) == 0 else {
            throw ConsoleError.directoryNotPrivate(path: path, reason: "it cannot be read (errno \(errno))")
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw ConsoleError.directoryNotPrivate(path: path, reason: "it is not a directory")
        }
        guard status.st_uid == geteuid() else {
            throw ConsoleError.directoryNotPrivate(path: path, reason: "it belongs to another user")
        }
        guard status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw ConsoleError.directoryNotPrivate(path: path, reason: "group or others have access (mode must be 0700)")
        }
    }

    private static func removeStaleSocket(at path: String) throws {
        var status = stat()
        if unsafe lstat(path, &status) != 0 {
            guard errno == ENOENT else { throw ConsoleError.system(call: "lstat", code: errno) }
            return
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else { throw ConsoleError.notASocket(path) }
        guard status.st_uid == geteuid() else { throw ConsoleError.notOwnedByUser(path) }
        // A socket that still accepts a connection is served by a live process; one that refuses is a leftover.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ConsoleError.system(call: "socket", code: errno) }
        defer { close(probe) }
        let connected = try connect(probe, to: path)
        if connected == 0 { throw ConsoleError.socketInUse(path) }
        guard errno == ECONNREFUSED || errno == ENOENT else { throw ConsoleError.system(call: "connect", code: errno) }
        _ = unsafe unlink(path)
    }

    // MARK: Accepting and connecting

    /// The next waiting connection (prepared: non-blocking, close-on-exec), or `nil` when none waits.
    package static func accept(_ listener: Int32) -> Int32? {
        while true {
            let descriptor = Darwin.accept(listener, nil, nil)
            if descriptor >= 0 {
                // A peer that already left makes the socket options fail (EINVAL); that connection is simply gone.
                guard prepare(descriptor, nonBlocking: true) else {
                    close(descriptor)
                    continue
                }
                return descriptor
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    /// The user id of the process on the other end of a local socket (`getpeereid`), or nil when the kernel cannot say.
    package static func peerUser(_ descriptor: Int32) -> UInt32? {
        var user: uid_t = 0
        var group: gid_t = 0
        // `getpeereid` writes one uid and one gid.
        guard unsafe getpeereid(descriptor, &user, &group) == 0 else { return nil }
        return user
    }

    /// Whether the process on the other end of a local socket runs as this user.
    static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        peerUser(descriptor) == geteuid()
    }

    /// A blocking connection to the console at `path`.
    package static func connect(to path: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw ConsoleError.pathNotAbsolute(path) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ConsoleError.system(call: "socket", code: errno) }
        do {
            // Before connecting: once the console has closed its end (a refused client), the options can no longer be set.
            guard prepare(descriptor, nonBlocking: false) else { throw ConsoleError.system(call: "fcntl", code: errno) }
            let result = try connect(descriptor, to: path)
            guard result == 0 else {
                switch errno {
                case ENOENT, ECONNREFUSED: throw ConsoleError.notServed(path)
                default: throw ConsoleError.system(call: "connect", code: errno)
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    // MARK: Waiting

    /// Waits until `descriptor` is readable (or writable), up to `milliseconds`. Returns false on timeout.
    package static func wait(_ descriptor: Int32, forWriting: Bool = false, milliseconds: Int32) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(forWriting ? POLLOUT : POLLIN), revents: 0)
        while true {
            // One entry, one descriptor.
            let ready = unsafe poll(&entry, 1, max(milliseconds, 0))
            if ready < 0, errno == EINTR { continue }
            return ready > 0
        }
    }
}
