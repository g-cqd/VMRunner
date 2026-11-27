import Foundation
import Synchronization
import Testing

@testable import GuestConsole

/// The forwarder on real sockets, with a socket pair standing in for each connection into the guest. Waits are on I/O; the
/// time limits only guard against a hang.
struct PortForwarderTests {
    /// Each `open` hands the forwarder one end of a new socket pair and keeps the other, the guest's, for the test.
    final class FakeGuest: Sendable {
        private let ends = Mutex<[GuestEnd]>([])
        let released = Atomic<Int>(0)
        let refuses: Bool

        init(refuses: Bool = false) { self.refuses = refuses }

        func open() -> PortForwarder.Channel? {
            guard !refuses, let pair = ConsoleSocket.streamPair(bufferBytes: 64 * 1024) else { return nil }
            ends.withLock { $0.append(GuestEnd(descriptor: pair.second)) }
            return PortForwarder.Channel(descriptor: pair.first) { [self] in released.add(1, ordering: .sequentiallyConsistent) }
        }

        /// The guest's end of the `index`-th connection, once it exists.
        func end(_ index: Int) async throws -> GuestEnd {
            for _ in 0..<500 {
                if let end = ends.withLock({ $0.count > index ? $0[index] : nil }) { return end }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ConsoleError.system(call: "open", code: ETIMEDOUT)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func bytesFlowBothWaysAndAnEndOnEitherSideClosesTheOther() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let guest = FakeGuest()
        let forwarder = try PortForwarder(socketPath: scratch.socket) { guest.open() }
        forwarder.start()
        defer { forwarder.stop() }

        let client = try ClientEnd(path: scratch.socket)
        let inside = try await guest.end(0)
        try client.send("SSH-2.0-client\r\n")
        #expect(inside.receive(count: 16) == Array("SSH-2.0-client\r\n".utf8))
        inside.send("SSH-2.0-server\r\n")
        #expect(client.receive(count: 16) == Array("SSH-2.0-server\r\n".utf8))

        // A large transfer in both directions at once, the case that would block a single relay thread.
        let payload = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        async let toGuest = Task.detached { inside.receive(count: payload.count) }.value
        async let toClient = Task.detached { client.receive(count: payload.count) }.value
        let sender = Task.detached { try ConsoleSocket.writeAll(client.descriptor, payload, stallMilliseconds: 10_000) }
        try ConsoleSocket.writeAll(inside.descriptor, payload, stallMilliseconds: 10_000)
        try await sender.value
        #expect(await toGuest == payload)
        #expect(await toClient == payload)

        // The guest leaves: the client sees the end of the stream, and the channel is released once both sides ended.
        inside.close()
        #expect(client.receive(count: 1).isEmpty)
        client.close()
        for _ in 0..<500 where guest.released.load(ordering: .sequentiallyConsistent) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(guest.released.load(ordering: .sequentiallyConsistent) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func connectionsAreIndependentAndAGuestThatRefusesClosesOnlyItsClient() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let guest = FakeGuest()
        let forwarder = try PortForwarder(socketPath: scratch.socket) { guest.open() }
        forwarder.start()
        defer { forwarder.stop() }

        let first = try ClientEnd(path: scratch.socket)
        let firstInside = try await guest.end(0)
        let second = try ClientEnd(path: scratch.socket)
        let secondInside = try await guest.end(1)
        try second.send("two")
        try first.send("one")
        #expect(firstInside.receive(count: 3) == Array("one".utf8))
        #expect(secondInside.receive(count: 3) == Array("two".utf8))
        first.close()
        second.close()

        let refusing = FakeGuest(refuses: true)
        let other = scratch.path + "/r.sock"
        let refused = try PortForwarder(socketPath: other) { refusing.open() }
        refused.start()
        defer { refused.stop() }
        let client = try ClientEnd(path: other)
        #expect(client.receive(count: 1).isEmpty)
        client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func stopRemovesTheSocketAndEndsTheRelaysRunningNow() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let guest = FakeGuest()
        let forwarder = try PortForwarder(socketPath: scratch.socket) { guest.open() }
        forwarder.start()
        let client = try ClientEnd(path: scratch.socket)
        _ = try await guest.end(0)

        forwarder.stop()
        #expect(client.receive(count: 1).isEmpty)
        client.close()
        for _ in 0..<500 where FileManager.default.fileExists(atPath: scratch.socket) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.socket))
        #expect(throws: (any Error).self) { try ConsoleSocket.connect(to: scratch.socket) }
    }

    @Test func aSocketInAFolderOthersCanEnterIsRefused() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        _ = unsafe chmod(scratch.path, 0o755)
        #expect(throws: ConsoleError.self) { try PortForwarder(socketPath: scratch.socket) { nil } }
    }
}
