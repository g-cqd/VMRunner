import Foundation
import Synchronization

@testable import GuestConsole

/// A private scratch directory with a short path (a local socket path holds about 100 bytes), removed by `remove()`.
struct ScratchDirectory {
    let path: String

    init() throws {
        path = "/tmp/gct-" + String(UInt32.random(in: 0...UInt32.max), radix: 16)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    var socket: String { path + "/c.sock" }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The guest's end of the console's socket pair, driven by a test.
struct GuestEnd: Sendable {
    let descriptor: Int32

    func send(_ text: String) {
        send(Array(text.utf8))
    }

    func send(_ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { unsafe Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { sent += count } else if count < 0, errno != EINTR { return }
        }
    }

    /// Reads exactly `count` bytes, or fewer when the stream ends or `seconds` pass without a byte (a guard against a hang).
    func receive(count: Int, seconds: Int32 = 10) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count < count, ConsoleSocket.wait(descriptor, milliseconds: seconds * 1_000) {
            let wanted = min(count - result.count, buffer.count)
            guard case .transferred(let got) = ConsoleSocket.read(descriptor, into: &buffer, limit: wanted) else { break }
            result.append(contentsOf: buffer[0..<got])
        }
        return result
    }

    func close() {
        ConsoleSocket.close(descriptor)
    }
}

/// A client socket connected to a bridge, read with a guard against a hang.
struct ClientEnd: Sendable {
    let descriptor: Int32

    init(path: String) throws {
        descriptor = try ConsoleSocket.connect(to: path)
    }

    func send(_ text: String) throws {
        try ConsoleSocket.writeAll(descriptor, Array(text.utf8), stallMilliseconds: 10_000)
    }

    /// Reads until `count` bytes arrived, the stream ended, or `seconds` passed without a byte.
    func receive(count: Int, seconds: Int32 = 10) -> [UInt8] {
        GuestEnd(descriptor: descriptor).receive(count: count, seconds: seconds)
    }

    /// One read: whatever is available once something arrives. Empty when the stream ended or `seconds` passed without a byte.
    func receiveSome(seconds: Int32 = 10) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        guard ConsoleSocket.wait(descriptor, milliseconds: seconds * 1_000),
            case .transferred(let got) = ConsoleSocket.read(descriptor, into: &buffer)
        else { return [] }
        return Array(buffer[0..<got])
    }

    /// Reads until the stream ends; returns everything it sent.
    func receiveUntilEnd(seconds: Int32 = 10) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while ConsoleSocket.wait(descriptor, milliseconds: seconds * 1_000) {
            guard case .transferred(let got) = ConsoleSocket.read(descriptor, into: &buffer) else { break }
            result.append(contentsOf: buffer[0..<got])
        }
        return result
    }

    func close() {
        ConsoleSocket.close(descriptor)
    }
}

/// A bridge on a scratch directory with a fake guest. `finish()` stops it and removes the directory.
struct BridgeRig {
    let scratch: ScratchDirectory
    let bridge: ConsoleBridge
    let guest: GuestEnd

    init() throws {
        scratch = try ScratchDirectory()
        let pair = try ConsoleBridge.makeGuestPair()
        do {
            bridge = try ConsoleBridge(guestDescriptor: pair.host, socketPath: scratch.socket)
        } catch {
            ConsoleSocket.close(pair.host)
            ConsoleSocket.close(pair.guest)
            scratch.remove()
            throw error
        }
        guest = GuestEnd(descriptor: pair.guest)
        bridge.start()
    }

    func finish() async {
        bridge.stop()
        await bridge.waitUntilFinished()
        guest.close()
        scratch.remove()
    }
}

/// A console transport that replays a script on a virtual clock, so timeouts and quiet periods cost no real time.
final class ScriptedTransport: ConsoleTransport {
    private enum Arrival {
        case bytes([UInt8])
        case end
    }

    private var arrivals: [(at: Duration, what: Arrival)] = []
    private(set) var clock = Duration.zero
    private(set) var written: [[UInt8]] = []
    /// Called with each write; may queue the console's answer.
    var onWrite: ((ScriptedTransport, [UInt8]) -> Void)?

    var uptime: Duration { clock }

    func arrive(_ text: String, after delay: Duration = .zero) {
        arrive(bytes: Array(text.utf8), after: delay)
    }

    func arrive(bytes: [UInt8], after delay: Duration = .zero) {
        arrivals.append((clock + delay, .bytes(bytes)))
        arrivals.sort { $0.at < $1.at }
    }

    func arriveEnd(after delay: Duration = .zero) {
        arrivals.append((clock + delay, .end))
        arrivals.sort { $0.at < $1.at }
    }

    var writtenText: [String] { written.map { lossyText($0) } }

    func read(timeout: Duration) throws -> TransportRead {
        guard let next = arrivals.first, next.at <= clock + timeout else {
            clock += timeout
            return .timedOut
        }
        arrivals.removeFirst()
        clock = max(clock, next.at)
        switch next.what {
        case .bytes(let bytes): return .bytes(bytes)
        case .end: return .endOfStream
        }
    }

    func write(_ bytes: [UInt8]) throws {
        written.append(bytes)
        onWrite?(self, bytes)
    }

    func close() {}
}

/// A deterministic pseudo-random sequence for chunking tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
