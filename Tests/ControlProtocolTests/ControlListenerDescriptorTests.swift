import Foundation
import GuestConsole
import Testing

@testable import ControlProtocol

/// The listener closes every connection it accepts, whichever way the connection ends, and a run of mixed connections leaves
/// no descriptor open. The client of each path reads the end of file, which only the server's close can bring. The listeners
/// are real, on sockets in a short private folder under /tmp; the suite is serialized and holds a minute at most.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ControlListenerDescriptorTests {
    /// The ways a connection can end. Each has a listener of its own, set up so that only this way ends it.
    enum Path: CaseIterable, Sendable {
        case normalCall
        case otherUser
        case pastConnectionLimit
        case requestTooLong
        case silent
        case requestsExhausted
        case listenerStops
    }

    struct Service: Sendable {
        let listener: ControlListener
        let path: String
    }

    struct Rig {
        let folder: ScratchFolder
        let secret: String
        let services: [Path: Service]

        init() throws {
            let folder = try ScratchFolder(in: URL(filePath: "/tmp", directoryHint: .isDirectory))
            let store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
            let machines = FakeMachines([ControlMachine.fake("m")])
            let dispatcher = ControlDispatcher(tokens: store, machines: machines, report: { _ in })
            var services: [Path: Service] = [:]
            for path in Path.allCases {
                var limits = ControlLimits()
                // Patient unless the path is the patience: a connection ends only the way its path says.
                limits.readTimeoutMilliseconds = 60_000
                var peerUser: @Sendable (Int32) -> UInt32? = ControlPeer.user(of:)
                switch path {
                case .otherUser: peerUser = { _ in ControlPeer.currentUser &+ 1 }
                case .pastConnectionLimit: limits.connections = 1
                case .requestTooLong: limits.requestBytes = 1_024
                case .silent: limits.readTimeoutMilliseconds = 50
                case .requestsExhausted: limits.requestsPerConnection = 2
                case .normalCall, .listenerStops: break
                }
                let socket = folder.url.appending(path: "\(path).sock").path
                let connection = ControlConnection(dispatcher: dispatcher, limits: limits, peerUser: peerUser)
                services[path] = Service(listener: try ControlListener(path: socket, connection: connection, limits: limits), path: socket)
            }
            self.folder = folder
            self.secret = try store.create(name: "t", capabilities: [.list]).secret
            self.services = services
        }

        /// Stops every listener, waits until each has closed its socket, and removes the folder.
        func shutDown() async {
            for service in services.values { service.listener.stop() }
            for service in services.values { await service.listener.waitUntilStopped() }
            folder.cleanUp()
        }

        // MARK: Clients

        /// A client on a socket that never blocks, whose every wait ends: a service that did not close shows as `timedOut`.
        func connect(_ path: Path) throws -> ControlClient {
            let descriptor = try ConsoleSocket.connect(to: try #require(services[path]).path)
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                ConsoleSocket.close(descriptor)
                throw ControlClientError.system(errno)
            }
            return ControlClient(descriptor: descriptor, timeoutMilliseconds: 10_000)
        }

        func attempt<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, any Error> {
            await runOnThread { Result(catching: work) }
        }

        func call(_ client: ControlClient, id: Int = 1) async throws -> ControlAnswer {
            let secret = self.secret
            return try await attempt { try client.call("machines.list", id: id, params: ["token": .string(secret)]) }.get()
        }

        func receive(_ client: ControlClient) async throws -> ControlAnswer? {
            try await attempt { try client.receive() }.get()
        }

        /// The client closes its sending side: the service reads the end of the stream and must close its own end.
        func halfClose(_ client: ControlClient) {
            _ = shutdown(client.descriptor, SHUT_WR)
        }

        /// Whether the service closed (or refused) a connection: the client's send or read sees it gone.
        static func isClosedByTheService(_ error: any Error) -> Bool {
            switch error {
            case ControlClientError.closed, ConsoleError.closed: true
            default: false
            }
        }

        // MARK: Paths

        /// Runs `path` once and returns the connections it made. Every expectation is that the client reads the end of file.
        func run(_ path: Path) async throws -> Int {
            switch path {
            case .normalCall: return try await normalCall()
            case .otherUser, .silent: return try await closedWithoutAWord(path)
            case .pastConnectionLimit: return try await pastConnectionLimit()
            case .requestTooLong: return try await requestTooLong()
            case .requestsExhausted: return try await requestsExhausted()
            case .listenerStops: return try await listenerStops()
            }
        }

        private func normalCall() async throws -> Int {
            let client = try connect(.normalCall)
            defer { client.close() }
            #expect(try await call(client).errorCode == nil)
            halfClose(client)
            #expect(try await receive(client) == nil, "a client that closed its end is answered with the service closing its own")
            return 1
        }

        /// A client of another user, and a client that sends nothing past the read limit, are closed without an answer.
        private func closedWithoutAWord(_ path: Path) async throws -> Int {
            let client = try connect(path)
            defer { client.close() }
            #expect(try await receive(client) == nil, "\(path) ends with the service closing the connection")
            return 1
        }

        /// Connects and calls until the listener has a place to give (a client refused for want of one is closed by the listener
        /// and tried again), so that the place the last client held is known to be back. Returns the client holding the place.
        func holdAPlace() async throws -> (client: ControlClient, connections: Int) {
            for connections in 1...50_000 {
                let client = try connect(.pastConnectionLimit)
                do {
                    #expect(try await call(client).errorCode == nil)
                    return (client, connections)
                } catch {
                    client.close()
                    guard Self.isClosedByTheService(error) else { throw error }
                    await Task.yield()
                }
            }
            throw ControlClientError.closed
        }

        private func pastConnectionLimit() async throws -> Int {
            let (held, connections) = try await holdAPlace()
            defer { held.close() }
            let refused = try connect(.pastConnectionLimit)
            defer { refused.close() }
            #expect(try await receive(refused) == nil, "the client past the limit is closed without an answer")
            halfClose(held)
            #expect(try await receive(held) == nil, "the client that held the place is closed after its end of stream")
            return connections + 1
        }

        private func requestTooLong() async throws -> Int {
            let client = try connect(.requestTooLong)
            defer { client.close() }
            let tooLong = Data(repeating: UInt8(ascii: "x"), count: 2_000)
            try await attempt { try client.send(tooLong) }.get()
            #expect(try await receive(client)?.errorCode == -32600, "the request is refused as too long")
            #expect(try await receive(client) == nil, "and the connection is closed after the refusal")
            return 1
        }

        private func requestsExhausted() async throws -> Int {
            let client = try connect(.requestsExhausted)
            defer { client.close() }
            for id in 1...2 {
                #expect(try await call(client, id: id).errorCode == nil)
            }
            #expect(try await receive(client) == nil, "closed after the last request it may send")
            return 1
        }

        /// Clients with a place each, then the listener stops: the request each sends next is not run, and its connection closes.
        private func listenerStops() async throws -> Int {
            let service = try #require(services[.listenerStops])
            let clients = try (0..<ControlLimits().connections).map { _ in try connect(.listenerStops) }
            defer { for client in clients { client.close() } }
            for client in clients {
                #expect(try await call(client).errorCode == nil)
            }
            service.listener.stop()
            await service.listener.waitUntilStopped()
            for client in clients {
                let late = await attempt { try client.call("machines.list", id: 2, params: [:]) }
                #expect(throws: ControlClientError.closed) { try late.get() }
            }
            return clients.count
        }
    }

    /// The fewest descriptors this process held over five reads of /dev/fd: a read that meets another suite's brief socket is
    /// outvoted. The directory read holds a descriptor of its own, the same in every read.
    static func openDescriptors() async throws -> Int {
        var fewest = Int.max
        for _ in 0..<5 {
            fewest = min(fewest, try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count)
            await Task.yield()
        }
        return fewest
    }

    /// Runs `body` on a fresh rig and shuts it down whatever happens, so the listeners of one test are gone before the next counts.
    static func withRig(_ body: (Rig) async throws -> Void) async throws {
        let rig = try Rig()
        do {
            try await body(rig)
        } catch {
            await rig.shutDown()
            throw error
        }
        await rig.shutDown()
    }

    @Test(arguments: Path.allCases)
    func theListenerClosesTheConnectionOnThisPath(path: Path) async throws {
        try await Self.withRig { rig in
            let made = try await rig.run(path)
            #expect(made >= 1)
        }
    }

    @Test
    func manyMixedConnectionsLeaveNoDescriptorBehind() async throws {
        try await Self.withRig { rig in
            let before = try await Self.openDescriptors()

            var connections = 0
            // The paths in turn, the stop last (it ends a listener); the clients of one path are closed before the next begins.
            while connections < 120 {
                for path in Path.allCases where path != .listenerStops { connections += try await rig.run(path) }
            }
            connections += try await rig.run(.listenerStops)
            #expect(connections >= 128)

            // A call that succeeds on the listener with one place: the place the last client held is free again.
            let last = try await rig.holdAPlace()
            connections += last.connections
            last.client.close()
            let after = try await Self.openDescriptors()
            #expect(
                after - before < 32,
                """
                \(connections) connections took the descriptor count from \(before) to \(after). The slack of 32 absorbs other \
                suites running in parallel (.serialized orders only this suite); a descriptor leaked per connection would show \
                about +128.
                """)
        }
    }
}
