import Foundation
import GuestConsole
import Testing

@testable import ControlProtocol

/// The listener on a real socket in a short private folder under /tmp (a local socket path holds at most 103 bytes).
struct ControlListenerTests {
    /// A short private folder, a store with one list-only token, and a connection over one fake machine.
    struct Rig {
        let folder: ScratchFolder
        let secret: String
        let path: String
        let store: ControlTokenStore

        init() throws {
            folder = try ScratchFolder(in: URL(filePath: "/tmp", directoryHint: .isDirectory))
            store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
            secret = try store.create(name: "t", capabilities: [.list]).secret
            path = folder.url.appending(path: "control.sock").path
        }

        func connection(_ limits: ControlLimits = ControlLimits(), machineCount: Int = 1) -> ControlConnection {
            let machines = FakeMachines((0..<machineCount).map { ControlMachine.fake("m\($0)") })
            let dispatcher = ControlDispatcher(tokens: store, machines: machines, report: { _ in })
            return ControlConnection(dispatcher: dispatcher, limits: limits)
        }

        /// Connects, lists, and closes, on a thread of its own.
        func list() async throws -> ControlAnswer {
            let path = self.path
            let secret = self.secret
            return try await runOnThread {
                Result { () throws -> ControlAnswer in
                    let client = try ControlClient.connect(to: path)
                    defer { client.close() }
                    return try client.call("machines.list", params: ["token": .string(secret)])
                }
            }.get()
        }
    }

    @Test
    func theSocketIsPrivateAnswersAClientAndIsRemovedWhenStopped() async throws {
        let rig = try Rig()
        defer { rig.folder.cleanUp() }
        let listener = try ControlListener(path: rig.path, connection: rig.connection())
        let mode = try FileManager.default.attributesOfItem(atPath: rig.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        #expect(try await rig.list().errorCode == nil)

        listener.stop()
        await listener.waitUntilStopped()
        #expect(!FileManager.default.fileExists(atPath: rig.path))
    }

    @Test
    func aPathTooLongForALocalSocketIsRefused() throws {
        let rig = try Rig()
        defer { rig.folder.cleanUp() }
        let path = rig.folder.url.appending(path: String(repeating: "s", count: 120)).path
        #expect(throws: ConsoleError.pathTooLong(path: path, limit: ConsoleBridge.socketPathLimit)) {
            _ = try ControlListener(path: path, connection: rig.connection())
        }
    }

    @Test
    func aDirectoryOpenToOthersIsRefused() throws {
        let rig = try Rig()
        defer { rig.folder.cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.folder.url.path)
        #expect(throws: ConsoleError.self) { _ = try ControlListener(path: rig.path, connection: rig.connection()) }
        #expect(!FileManager.default.fileExists(atPath: rig.path))
    }

    @Test
    func aSecondListenerOnALiveSocketIsRefused() async throws {
        let rig = try Rig()
        defer { rig.folder.cleanUp() }
        let first = try ControlListener(path: rig.path, connection: rig.connection())
        #expect(throws: ConsoleError.socketInUse(rig.path)) { _ = try ControlListener(path: rig.path, connection: rig.connection()) }
        first.stop()
        await first.waitUntilStopped()
    }

    @Test
    func aClientPastTheConnectionLimitIsClosedAtOnce() async throws {
        let rig = try Rig()
        defer { rig.folder.cleanUp() }
        var limits = ControlLimits()
        limits.connections = 1
        // The held client keeps its place for the whole test, however slow the run.
        limits.readTimeoutMilliseconds = 60_000
        let listener = try ControlListener(path: rig.path, connection: rig.connection(limits), limits: limits)
        let path = rig.path
        let secret = rig.secret
        // The first client holds the only place: once it has its answer, its connection waits for the next request.
        let held = try ControlClient.connect(to: path)
        defer { held.close() }
        let first = try await runOnThread { Result { try held.call("machines.list", params: ["token": .string(secret)]) } }.get()
        #expect(first.errorCode == nil)

        let refused = try await runOnThread {
            Result { () throws -> ControlAnswer? in
                let client = try ControlClient.connect(to: path)
                defer { client.close() }
                return try client.receive()
            }
        }.get()
        #expect(refused == nil, "closed without an answer")
        listener.stop()
        await listener.waitUntilStopped()
    }

    @Test
    func aClientConnectedWhenTheListenerStopsGetsNoMoreAnswers() async throws {
        let rig = try Rig()
        defer { rig.folder.cleanUp() }
        let listener = try ControlListener(path: rig.path, connection: rig.connection())
        let path = rig.path
        let secret = rig.secret
        let open = try ControlClient.connect(to: path)
        defer { open.close() }
        let first = try await runOnThread { Result { try open.call("machines.list", params: ["token": .string(secret)]) } }.get()
        #expect(first.errorCode == nil)

        listener.stop()
        await listener.waitUntilStopped()
        let late = await runOnThread { Result { try open.call("machines.list", params: ["token": .string(secret)]) } }
        #expect(throws: ControlClientError.closed) { try late.get() }
    }

    @Test
    func aClientThatStopsReadingIsDroppedRatherThanWaitedFor() async throws {
        let rig = try Rig()
        defer { rig.folder.cleanUp() }
        var limits = ControlLimits()
        limits.writeStallMilliseconds = 100
        // Far more machines than the socket buffers hold: the answer cannot be written unless the client reads it.
        let listener = try ControlListener(path: rig.path, connection: rig.connection(limits, machineCount: 600), limits: limits)
        let silent = try ControlClient.connect(to: rig.path)
        defer { silent.close() }
        let request = #"{"jsonrpc":"2.0","id":1,"method":"machines.list","params":{"token":"\#(rig.secret)"}}"#
        let closed = try await runOnThread {
            Result { () throws -> Bool in
                try silent.send(Data(request.utf8))
                // Not reading for far longer than the stall: the service gives up on the answer and closes the connection.
                Thread.sleep(forTimeInterval: 0.5)
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while ConsoleSocket.wait(silent.descriptor, milliseconds: 3_000) {
                    switch ConsoleSocket.read(silent.descriptor, into: &buffer) {
                    case .endOfStream, .failed: return true
                    case .transferred, .wouldBlock: continue
                    }
                }
                return false
            }
        }.get()
        #expect(closed, "the connection was closed instead of waiting for the reader")
        listener.stop()
        await listener.waitUntilStopped()
    }

    @Test
    func theLimiterGivesOutAtMostItsLimitAndTakesPlacesBack() {
        let limiter = ConnectionLimiter(limit: 2)
        #expect(limiter.acquire() && limiter.acquire())
        #expect(!limiter.acquire())
        limiter.release()
        #expect(limiter.acquire())
        #expect(limiter.count == 2)
    }
}
