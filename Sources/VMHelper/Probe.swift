import Foundation
import VMHelperCore
import Virtualization

/// `--probe`: the operations a guest-hosting helper needs, tried one by one inside whatever sandbox it was launched in,
/// without building a machine. Each result is a `probe` event; none of them is an error, because "refused" is the answer a
/// sandbox is supposed to give to some of them.
struct Probe {
    let descriptor: HelperDescriptor
    let emitter: Emitter

    func run() {
        for path in descriptor.readPaths { report("read granted file \(path)", Self.open(path, O_RDONLY)) }
        for path in descriptor.readWritePaths { report("read and write granted file \(path)", Self.open(path, O_RDWR)) }
        reportOutside()
        reportVirtualization()
        reportSockets()
        reportNames()
    }

    // MARK: Files

    private func reportOutside() {
        report("read /etc/hosts", Self.open("/etc/hosts", O_RDONLY))
        let check = "list the real home directory"
        // The user database first (a sandboxed process's HOME is its container), the environment when the sandbox hides it.
        let account = unsafe getpwuid(getuid()).flatMap { unsafe String(cString: $0.pointee.pw_dir) }
        if let home = account ?? ProcessInfo.processInfo.environment["HOME"] {
            if let directory = unsafe opendir(home) {
                unsafe closedir(directory)
                emitter.emit(.probe, message: "listed", check: check, verdict: .allowed)
            } else {
                emitter.emit(.probe, message: Self.describe(errno), check: check, verdict: .refused)
            }
        } else {
            emitter.emit(
                .probe, message: "neither the user database nor HOME names a home directory", check: check,
                verdict: .inconclusive)
        }
        let scratch = "/private/tmp/vmhelper-probe-\(ProcessInfo.processInfo.processIdentifier)"
        let descriptor = Self.open(scratch, O_WRONLY | O_CREAT | O_EXCL)
        if descriptor >= 0 { _ = unsafe unlink(scratch) }
        report("create a file under /private/tmp", descriptor)
    }

    /// `open(2)` for a path that is passed as a C string.
    private static func open(_ path: String, _ flags: Int32) -> Int32 {
        // `open` reads the NUL-terminated copy of `path` that the call makes.
        unsafe Darwin.open(path, flags, 0o600)
    }

    /// `descriptor` is the result of an `open`; it is closed here.
    private func report(_ check: String, _ descriptor: Int32) {
        let failure = errno
        if descriptor >= 0 {
            close(descriptor)
            emitter.emit(.probe, message: "opened", check: check, verdict: .allowed)
        } else if failure == ENOENT {
            emitter.emit(.probe, message: "does not exist, so nothing was learned", check: check, verdict: .inconclusive)
        } else {
            emitter.emit(.probe, message: Self.describe(failure), check: check, verdict: .refused)
        }
    }

    // MARK: Virtualization

    private func reportVirtualization() {
        emitter.emit(
            .probe, message: "VZVirtualMachine.isSupported", check: "virtualization is supported on this host",
            verdict: .init(allowed: VZVirtualMachine.isSupported))
    }

    // MARK: Sockets

    private func reportSockets() {
        reportSocketPair()
        reportSocket("create a TCP socket", type: SOCK_STREAM) { _ in 0 }
        reportSocket(ProbeCheck.tcpConnect, type: SOCK_STREAM) { Self.connectLoopback($0) }
        reportSocket(ProbeCheck.udpSend, type: SOCK_DGRAM) { Self.sendDatagram($0) }
        reportSocket(ProbeCheck.icmpConnect, type: SOCK_DGRAM, protocolNumber: IPPROTO_ICMP) {
            Self.connectLoopback($0)
        }
        reportSocket(ProbeCheck.udpBind, type: SOCK_DGRAM) { Self.bindLoopback($0) }
    }

    private func reportSocketPair() {
        guard let pair = DatagramPair.make() else {
            emitter.emit(.probe, message: Self.describe(errno), check: ProbeCheck.socketPair, verdict: .refused)
            return
        }
        defer {
            close(pair.guest)
            close(pair.host)
        }
        let byte: [UInt8] = [0x42]
        var received: [UInt8] = [0]
        let sent = unsafe send(pair.host, byte, 1, 0)
        let read = unsafe recv(pair.guest, &received, 1, 0)
        let works = sent == 1 && read == 1 && received == byte
        emitter.emit(
            .probe, message: works ? "a datagram crossed the pair" : Self.describe(errno), check: ProbeCheck.socketPair,
            verdict: .init(allowed: works))
    }

    /// Runs `operation` on a fresh socket. The operation returns a negative value with `errno` set when it fails; a refusal
    /// is `EPERM` or `EACCES`, any other failure (a closed port, a missing route) means the sandbox let the call through.
    private func reportSocket(_ check: String, type: Int32, protocolNumber: Int32 = 0, _ operation: (Int32) -> Int32) {
        let descriptor = socket(AF_INET, type, protocolNumber)
        guard descriptor >= 0 else {
            emitter.emit(.probe, message: Self.describe(errno), check: check, verdict: .refused)
            return
        }
        defer { close(descriptor) }
        let result = operation(descriptor)
        let failure = errno
        if result >= 0 {
            emitter.emit(.probe, message: "succeeded", check: check, verdict: .allowed)
        } else if failure == EPERM || failure == EACCES {
            emitter.emit(.probe, message: Self.describe(failure), check: check, verdict: .refused)
        } else {
            emitter.emit(.probe, message: "passed the sandbox, then failed: \(Self.describe(failure))", check: check, verdict: .allowed)
        }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }

    private static func connectLoopback(_ descriptor: Int32) -> Int32 {
        var address = loopback(port: 9)
        // `connect` reads one `sockaddr_in`, passed as the generic `sockaddr`.
        return withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func sendDatagram(_ descriptor: Int32) -> Int32 {
        var address = loopback(port: 9)
        let byte: [UInt8] = [0]
        // `sendto` reads one byte and one `sockaddr_in`, passed as the generic `sockaddr`.
        let sent = withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe sendto(descriptor, byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return Int32(truncatingIfNeeded: sent)
    }

    private static func bindLoopback(_ descriptor: Int32) -> Int32 {
        var address = loopback(port: 0)
        // `bind` reads one `sockaddr_in`, passed as the generic `sockaddr`.
        return withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    // MARK: Names

    private func reportNames() {
        for name in [ProbeCheck.localHost, ProbeCheck.remoteHost] {
            var hints = unsafe addrinfo()
            unsafe hints.ai_family = AF_INET
            unsafe hints.ai_socktype = SOCK_STREAM
            var found: UnsafeMutablePointer<addrinfo>?
            // `getaddrinfo` takes C strings and fills `found`, which `freeaddrinfo` releases.
            let status = unsafe getaddrinfo(name, nil, &hints, &found)
            if status == 0 {
                unsafe freeaddrinfo(found)
                emitter.emit(.probe, message: "resolved", check: ProbeCheck.resolve(name), verdict: .allowed)
            } else {
                emitter.emit(
                    .probe, message: unsafe String(cString: gai_strerror(status)), check: ProbeCheck.resolve(name), verdict: .refused)
            }
        }
    }

    private static func describe(_ code: Int32) -> String {
        unsafe String(cString: strerror(code))
    }
}
