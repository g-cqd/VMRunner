import Foundation
import Synchronization

@testable import VMRunner

/// Blocking BSD-socket helpers for the loopback servers the integration tests talk to through the stack. (Plain
/// threads and sockets rather than NWListener, which needs a dispatch queue the repository's lint rules ban.)
enum TestSockets {
    static func loopbackAddress(port: UInt16 = 0) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        return address
    }

    /// A socket bound to 127.0.0.1 on a free port, listening if it is a stream socket. Returns the descriptor and port.
    static func bindLoopback(type: Int32) -> (descriptor: Int32, port: UInt16)? {
        let descriptor = socket(AF_INET, type, 0)
        guard descriptor >= 0 else { return nil }
        var address = loopbackAddress()
        let bound = withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, type != SOCK_STREAM || listen(descriptor, 64) == 0 else {
            close(descriptor)
            return nil
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            close(descriptor)
            return nil
        }
        return (descriptor, UInt16(bigEndian: assigned.sin_port))
    }

    static func accept(_ listener: Int32) -> Int32? {
        let accepted = Darwin.accept(listener, nil, nil)
        return accepted >= 0 ? accepted : nil
    }

    /// Reads up to `limit` bytes; empty at end of stream or on error.
    static func read(_ descriptor: Int32, limit: Int = 65_536) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = buffer.withUnsafeMutableBytes { unsafe Darwin.read(descriptor, $0.baseAddress, limit) }
        return count > 0 ? Array(buffer.prefix(count)) : []
    }

    @discardableResult
    static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                unsafe Darwin.write(descriptor, $0.baseAddress.map { unsafe $0 + offset }, bytes.count - offset)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    static func resetOnClose(_ descriptor: Int32) {
        var linger = linger(l_onoff: 1, l_linger: 0)
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
    }
}

/// A real TCP server on 127.0.0.1 with scripted behavior. Records how many connections it saw, so a test can assert that
/// a denied destination never received one.
final class LoopbackServer: Sendable {
    enum Behavior: Sendable {
        /// Echoes everything until the client half-closes, then closes.
        case echo
        /// Reads everything until end of stream, then answers with the byte count as text and closes.
        case sink
        /// Sends the bytes immediately and closes (the server closes first).
        case greeting([UInt8])
        /// Resets the connection right after accepting it.
        case reset
        /// Waits for the client's half-close, then sends the reply and closes (needs half-close to work).
        case replyAfterEOF([UInt8])
        /// Sends these bytes and closes (precomputed, so generating them is not part of a timed transfer).
        case bulk([UInt8])
    }

    private final class State: Sendable {
        let accepted = Mutex(0)
        let received = Mutex<[UInt8]>([])
    }

    let port: UInt16
    private let listener: Int32
    private let state = State()

    init?(_ behavior: Behavior) {
        guard let bound = TestSockets.bindLoopback(type: SOCK_STREAM) else { return nil }
        listener = bound.descriptor
        port = bound.port
        let descriptor = listener
        let shared = state
        Thread.detachNewThread {
            while let connection = TestSockets.accept(descriptor) {
                shared.accepted.withLock { $0 += 1 }
                Thread.detachNewThread { Self.serve(connection, behavior, shared) }
            }
        }
    }

    var connectionCount: Int { state.accepted.withLock { $0 } }
    var receivedBytes: [UInt8] { state.received.withLock { $0 } }

    /// Stops accepting. Connections already open finish on their own.
    func close() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private static func serve(_ connection: Int32, _ behavior: Behavior, _ shared: State) {
        defer { Darwin.close(connection) }
        switch behavior {
        case .echo:
            while case let chunk = TestSockets.read(connection), !chunk.isEmpty { TestSockets.writeAll(connection, chunk) }
            shutdown(connection, SHUT_WR)
        case .sink:
            var total = 0
            while case let chunk = TestSockets.read(connection), !chunk.isEmpty {
                total += chunk.count
                shared.received.withLock { $0 += chunk }
            }
            TestSockets.writeAll(connection, Array("received \(total)".utf8))
        case .greeting(let bytes):
            TestSockets.writeAll(connection, bytes)
        case .reset:
            TestSockets.resetOnClose(connection)
        case .replyAfterEOF(let reply):
            while !TestSockets.read(connection).isEmpty {}
            TestSockets.writeAll(connection, reply)
        case .bulk(let bytes):
            TestSockets.writeAll(connection, bytes)
        }
    }
}

/// A UDP echo server on 127.0.0.1.
final class LoopbackUDPServer: Sendable {
    let port: UInt16
    private final class Counter: Sendable {
        let value = Mutex(0)
    }

    private let descriptor: Int32
    private let datagrams = Counter()

    init?() {
        guard let bound = TestSockets.bindLoopback(type: SOCK_DGRAM) else { return nil }
        descriptor = bound.descriptor
        port = bound.port
        let socket = descriptor
        let counter = datagrams
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                var peer = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &peer) { peerPointer in
                        unsafe peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            unsafe recvfrom(socket, raw.baseAddress, raw.count, 0, $0, &length)
                        }
                    }
                }
                guard count >= 0 else { return }
                counter.value.withLock { $0 += 1 }
                _ = buffer.withUnsafeBytes { raw in
                    withUnsafePointer(to: &peer) { peerPointer in
                        unsafe peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            unsafe sendto(socket, raw.baseAddress, count, 0, $0, length)
                        }
                    }
                }
            }
        }
    }

    var datagramCount: Int { datagrams.value.withLock { $0 } }

    func close() {
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }
}
