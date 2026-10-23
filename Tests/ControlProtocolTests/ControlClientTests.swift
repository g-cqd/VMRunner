import Foundation
import GuestConsole
import Testing

@testable import ControlProtocol

/// The client's own side: answers that arrive together, answers too deep or too long, requests sent ahead of their answers,
/// and one call per connection that refuses a socket served by another user.
struct ControlClientTests {
    /// A client on one end of a socket pair and the other end, from which a test writes answers by hand. The client waits
    /// one second at most, so a lost answer fails the test instead of holding it.
    private struct Pair {
        let client: ControlClient
        let server: Int32

        init(answerBytes: Int = ControlClient.defaultAnswerBytes) throws {
            let pair = try #require(ConsoleSocket.streamPair(bufferBytes: 64 * 1_024))
            client = ControlClient(descriptor: pair.first, timeoutMilliseconds: 1_000, answerBytes: answerBytes)
            server = pair.second
        }

        /// Writes `text` in one write; it is far smaller than the socket's buffer, so this never waits for the client.
        func answer(_ text: String) throws {
            try ConsoleSocket.writeAll(server, Array(text.utf8), stallMilliseconds: 1_000)
        }

        func close() {
            client.close()
            ConsoleSocket.close(server)
        }
    }

    @Test
    func twoAnswersThatArriveInOneReadAreBothReturned() throws {
        let pair = try Pair()
        defer { pair.close() }
        try pair.answer(#"{"id":1,"jsonrpc":"2.0","result":{}}"# + "\n" + #"{"id":2,"jsonrpc":"2.0","result":{}}"# + "\n")
        #expect(try pair.client.receive()?.id == 1)
        #expect(try pair.client.receive()?.id == 2, "the second answer was kept, not dropped with the first read")
    }

    @Test
    func anAnswerNestedTooDeeplyIsRefusedUnparsed() throws {
        let pair = try Pair()
        defer { pair.close() }
        let deep = String(repeating: "[", count: 2_000) + String(repeating: "]", count: 2_000)
        try pair.answer(#"{"id":1,"jsonrpc":"2.0","result":"# + deep + "}\n")
        #expect(throws: ControlClientError.malformedAnswer) { try pair.client.receive() }
    }

    @Test
    func anAnswerOneLevelPastTheNestingLimitIsRefused() throws {
        let pair = try Pair()
        defer { pair.close() }
        // The system parser reads nine levels without trouble, so only the client's own bound refuses this one.
        try pair.answer(#"{"id":1,"jsonrpc":"2.0","result":[[[[[[[[1]]]]]]]]}"# + "\n")
        #expect(throws: ControlClientError.malformedAnswer) { try pair.client.receive() }
    }

    @Test
    func anAnswerAtTheNestingLimitIsRead() throws {
        let pair = try Pair()
        defer { pair.close() }
        // The object is one level, seven arrays make eight.
        try pair.answer(#"{"id":1,"jsonrpc":"2.0","result":[[[[[[[1]]]]]]]}"# + "\n")
        let answer = try #require(try pair.client.receive())
        #expect(answer.result == Data("[[[[[[[1]]]]]]]".utf8))
    }

    @Test
    func anAnswerLongerThanTheClientAcceptsIsRefused() throws {
        let pair = try Pair(answerBytes: 64)
        defer { pair.close() }
        try pair.answer(String(repeating: "x", count: 100))
        #expect(throws: ControlClientError.answerTooLong) { try pair.client.receive() }
    }

    @Test
    func requestsSentAheadOfTheirAnswersAreAnsweredInOrder() async throws {
        let rig = try ControlConnectionTests.Rig()
        defer { rig.finish() }
        let client = rig.client
        let token = rig.token
        try await runOnThread {
            Result {
                try client.request("machines.list", id: 1, params: token)
                try client.request("machines.state", id: 2, params: token.merging(["machine": .string(UUID().uuidString)]) { $1 })
            }
        }.get()
        let first = try #require(try await rig.receive())
        let second = try #require(try await rig.receive())
        #expect(first.id == 1 && first.errorCode == nil)
        #expect(second.id == 2 && second.errorCode == -32002, "no such machine")
    }

    @Test
    func aCallerSendsItsOwnTokenOnAFreshConnectionAndReturnsTheAnswer() async throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
        let secret = try store.create(name: "test", capabilities: [.list]).secret
        let machine = ControlMachine.fake("m")
        let connection = ControlConnection(
            dispatcher: ControlDispatcher(tokens: store, machines: FakeMachines([machine]), report: { _ in }))
        // Each call gets a new socket pair whose other end a new served connection reads.
        let caller = ControlCaller(token: secret) {
            let pair = try ControlClient.connectedPair()
            let server = pair.server
            Task { await connection.serve(server) }
            return pair.client
        }
        for _ in 1...2 {
            let answer = try await runOnThread { Result { try caller.call(.list, params: ["token": .string("vmrc_other")]) } }.get()
            let list = try JSONDecoder().decode([String: [ControlMachine]].self, from: try #require(answer.result))
            #expect(list["machines"] == [machine], "the caller's own token replaced the one in params")
        }
    }

    @Test
    func aCallerSendsNothingToASocketServedByAnotherUser() throws {
        let pair = try #require(ConsoleSocket.streamPair(bufferBytes: 64 * 1_024))
        defer { ConsoleSocket.close(pair.second) }
        let caller = ControlCaller(
            token: "vmrc_secret", peerUser: { _ in ControlPeer.currentUser &+ 1 },
            connect: { ControlClient(descriptor: pair.first, timeoutMilliseconds: 1_000) })
        #expect(throws: ControlClientError.peerIsAnotherUser) { try caller.call(.list) }
        var buffer = [UInt8](repeating: 0, count: 64)
        #expect(ConsoleSocket.read(pair.second, into: &buffer) == .endOfStream, "closed with nothing written")
    }

    @Test
    func aCallerOfASocketNobodyServesSaysSo() {
        let path = "/tmp/vmr-no-such-control-\(UUID().uuidString.prefix(8)).sock"
        #expect(throws: ConsoleError.notServed(path)) { try ControlCaller(token: "vmrc_secret", socket: path).call(.list) }
    }
}
