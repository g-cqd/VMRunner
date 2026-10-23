import Foundation
import TestKit
import Testing

@testable import ControlProtocol

/// The protocol end to end over a connected pair of local sockets: this library's client against a served connection.
struct ControlConnectionTests {
    /// One served connection, with a dispatcher on one fake machine, a store in a scratch folder and a token holding every
    /// capability. A test calls `finish()` in a `defer`, so a failed check leaves nothing behind.
    struct Rig {
        let folder: ScratchFolder
        let store: ControlTokenStore
        let tokenID: UUID
        let machines: FakeMachines
        let machine: ControlMachine
        let denials: AsyncEventProbe<ControlDenial>
        let secret: String
        let client: ControlClient

        init(
            limits: ControlLimits = ControlLimits(), allowedUser: UInt32 = ControlPeer.currentUser, clock: TestClock = TestClock(),
            startGate: AsyncGate? = nil, isOpen: @escaping @Sendable () -> Bool = { true },
            peerUser: @escaping @Sendable (Int32) -> UInt32? = ControlPeer.user(of:)
        ) throws {
            let folder = try ScratchFolder()
            let store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
            let machine = ControlMachine.fake("m")
            let machines = FakeMachines([machine], startGate: startGate)
            let probe = AsyncEventProbe<ControlDenial>()
            let made = try store.create(name: "test", capabilities: Set(ControlCapability.allCases))
            let dispatcher = ControlDispatcher(tokens: store, machines: machines, report: { probe.record($0) })
            let connection = ControlConnection(
                dispatcher: dispatcher, limits: limits, peerUser: peerUser, allowedUser: allowedUser,
                sleep: { try await clock.sleep(for: $0) })
            let pair = try ControlClient.connectedPair()
            self.folder = folder
            self.store = store
            self.tokenID = made.token.id
            self.machines = machines
            self.machine = machine
            self.denials = probe
            self.secret = made.secret
            self.client = pair.client
            let server = pair.server
            Task { await connection.serve(server, while: isOpen) }
        }

        /// Each client call blocks, so it runs on a thread of its own and the test holds no shared thread.
        func call(_ method: String, id: Int = 1, _ params: [String: RPCValue] = [:]) async throws -> ControlAnswer {
            let client = self.client
            return try await runOnThread { Result { try client.call(method, id: id, params: params) } }.get()
        }

        func send(_ text: String) async throws {
            let client = self.client
            try await runOnThread { Result { try client.send(Data(text.utf8)) } }.get()
        }

        func receive() async throws -> ControlAnswer? {
            let client = self.client
            return try await runOnThread { Result { try client.receive() } }.get()
        }

        var token: [String: RPCValue] { ["token": .string(secret)] }

        /// Closes the client, which ends the served connection, and removes the folder. Called in a `defer`.
        func finish() {
            client.close()
            folder.cleanUp()
        }
    }

    @Test
    func aListCallGoesThroughTheSocketAndComesBack() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let answer = try await rig.call("machines.list", rig.token)
        let json = try #require(answer.result)
        let list = try JSONDecoder().decode([String: [ControlMachine]].self, from: json)
        #expect(list["machines"] == [rig.machine])
        #expect(answer.id == 1)
    }

    @Test
    func theKernelReportsThisProcessAsThePeerOfASocketPair() throws {
        let pair = try ControlClient.connectedPair()
        defer {
            pair.client.close()
            ControlClient(descriptor: pair.server).close()
        }
        #expect(ControlPeer.user(of: pair.server) == ControlPeer.currentUser)
    }

    @Test
    func aClientOfAnotherUserIsClosedBeforeAnythingIsRead() async throws {
        let rig = try Rig(allowedUser: ControlPeer.currentUser &+ 1)
        defer { rig.finish() }
        #expect(try await rig.receive() == nil, "closed at once, without an answer")
        let denial = try #require(rig.denials.events.first)
        #expect(denial.reason == .otherUser)
        #expect(denial.peerUser == ControlPeer.currentUser)
    }

    @Test
    func aClientWhosePeerCannotBeNamedIsClosedBeforeAnythingIsRead() async throws {
        let rig = try Rig(peerUser: { _ in nil })
        defer { rig.finish() }
        #expect(try await rig.receive() == nil, "closed at once, without an answer")
        let denial = try #require(rig.denials.events.first)
        #expect(denial.reason == .otherUser)
        #expect(denial.peerUser == nil)
        #expect(rig.machines.calls.events.isEmpty, "nothing was started")
    }

    @Test
    func malformedJSONIsAnsweredAndTheConnectionGoesOn() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.send("{not json")
        let first = try #require(try await rig.receive())
        #expect(first.errorCode == -32700)
        let second = try await rig.call("machines.list", id: 2, rig.token)
        #expect(second.id == 2 && second.errorCode == nil)
    }

    @Test
    func aBatchIsRefused() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.send(#"[{"jsonrpc":"2.0","id":1,"method":"machines.list"}]"#)
        let answer = try #require(try await rig.receive())
        #expect(answer.errorCode == -32600)
        #expect(answer.errorMessage?.contains("batches") == true)
    }

    @Test
    func aRequestLongerThanTheLimitIsRefusedAndTheConnectionClosed() async throws {
        var limits = ControlLimits()
        limits.requestBytes = 64
        let rig = try Rig(limits: limits)
        defer { rig.finish() }
        try await rig.send(String(repeating: "x", count: 100))
        let answer = try #require(try await rig.receive())
        #expect(answer.errorCode == -32600)
        #expect(answer.errorMessage?.contains("longer than 64 bytes") == true)
        #expect(try await rig.receive() == nil)
    }

    @Test
    func aNotificationIsNeitherRunNorAnswered() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let params = #""params":{"token":"\#(rig.secret)","machine":"\#(rig.machine.id.uuidString)"}"#
        let start = #"{"jsonrpc":"2.0","method":"machines.start","# + params + "}"
        try await rig.send(start)
        let answer = try await rig.call("machines.list", id: 2, rig.token)
        #expect(answer.id == 2, "the first answer is the list's: the notification got none")
        #expect(rig.machines.calls.events.isEmpty, "the notification started nothing")
    }

    @Test
    func aRevokedTokenFailsOnTheNextRequestOfAnOpenConnection() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        #expect(try await rig.call("machines.list", rig.token).errorCode == nil)
        try rig.store.revoke(rig.tokenID)
        let refused = try await rig.call("machines.list", id: 2, rig.token)
        #expect(refused.errorCode == -32001)
        #expect(rig.denials.events.map(\.reason) == [.unknownToken])
    }

    @Test
    func aRequestThatOutlivesItsTimeLimitIsAnsweredTimedOutAndWhatItStartedGoesOn() async throws {
        let clock = TestClock()
        let gate = AsyncGate()
        let rig = try Rig(clock: clock, startGate: gate)
        defer { rig.finish() }
        let params = rig.token.merging(["machine": .string(rig.machine.id.uuidString)]) { $1 }
        async let answer = rig.call("machines.start", params)
        // The start was made (recorded) and the deadline is waiting: only then does time pass.
        _ = try await rig.machines.calls.wait(forAtLeast: 1)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(120))
        #expect(try await answer.errorCode == -32005)
        #expect(rig.machines.calls.events == ["start \(rig.machine.id.uuidString)"])
        gate.open()
    }

    @Test
    func aConnectionTheListenerHasClosedGetsNoAnswerAndItsRequestIsNotRun() async throws {
        let rig = try Rig(isOpen: { false })
        defer { rig.finish() }
        let params = #""params":{"token":"\#(rig.secret)","machine":"\#(rig.machine.id.uuidString)"}"#
        try await rig.send(#"{"jsonrpc":"2.0","id":1,"method":"machines.start","# + params + "}")
        #expect(try await rig.receive() == nil, "closed without an answer")
        #expect(rig.machines.calls.events.isEmpty, "the request was not run")
    }

    @Test
    func aClientWaitsLongerThanTheServiceTakesToAnswer() {
        #expect(ControlClient(descriptor: -1).timeoutMilliseconds > 120_000)
    }

    @Test
    func anIdleConnectionIsClosedAfterTheReadLimit() async throws {
        var limits = ControlLimits()
        limits.readTimeoutMilliseconds = 50
        let rig = try Rig(limits: limits)
        defer { rig.finish() }
        #expect(try await rig.receive() == nil)
    }

    @Test
    func aConnectionServesAtMostItsNumberOfRequests() async throws {
        var limits = ControlLimits()
        limits.requestsPerConnection = 2
        let rig = try Rig(limits: limits)
        defer { rig.finish() }
        for id in 1...2 {
            #expect(try await rig.call("machines.list", id: id, rig.token).errorCode == nil)
        }
        #expect(try await rig.receive() == nil, "closed after the second answer")
    }

    @Test
    func aDeadlineReturnsTheOperationsResultWhenItComesFirst() async {
        let value = await withDeadline(.seconds(1), sleep: { try await Task.sleep(for: $0) }, { 42 })
        #expect(value == 42)
    }
}
