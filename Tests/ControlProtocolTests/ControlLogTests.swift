import Foundation
import TestKit
import Testing

@testable import ControlProtocol

/// `machines.log`: the same checks as every machine method, and an answer that is always the end of the log, at most
/// `ControlLog.maxBytes` of it, whatever the machines return.
struct ControlLogTests {
    private struct NotAResult: Error {
        let response: RPCResponse
    }

    private struct Rig {
        let folder: ScratchFolder
        let store: ControlTokenStore
        let machines: FakeMachines
        let dispatcher: ControlDispatcher

        init(_ list: [ControlMachine], logOutcome: ControlLogOutcome? = nil) throws {
            folder = try ScratchFolder()
            store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
            machines = FakeMachines(list, logOutcome: logOutcome)
            dispatcher = ControlDispatcher(tokens: store, machines: machines, report: { _ in })
        }

        func secret(_ capabilities: Set<ControlCapability>, machines: [UUID]? = nil) throws -> String {
            try store.create(name: "test", capabilities: capabilities, machines: machines).secret
        }

        func readLog(_ machine: UUID, secret: String) async -> RPCResponse {
            await dispatcher.answer(
                RPCRequest(
                    id: .number(1), method: ControlMethod.log.rawValue,
                    params: ["token": .string(secret), "machine": .string(machine.uuidString)]))
        }

        func log(_ response: RPCResponse) throws -> ControlLog {
            guard case .result(let json) = response.body else { throw NotAResult(response: response) }
            return try JSONDecoder().decode(ControlLog.self, from: json)
        }
    }

    @Test
    func theLogIsReadWithTheLogCapabilityOnly() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine])
        defer { rig.folder.cleanUp() }

        let answer = try rig.log(await rig.readLog(machine.id, secret: try rig.secret([.log])))
        #expect(answer == ControlLog(id: machine.id, text: "output of \(machine.id.uuidString)\n", truncated: false))
        let lacking = Set(ControlCapability.allCases).subtracting([.log])
        #expect(await rig.readLog(machine.id, secret: try rig.secret(lacking)).error?.code == -32001)
        #expect(rig.machines.calls.events == ["log \(machine.id.uuidString)"], "the refused call read nothing")
    }

    @Test
    func aMachineOutsideTheTokensScopeIsNotRead() async throws {
        let mine = ControlMachine.fake("mine")
        let other = ControlMachine.fake("other")
        let rig = try Rig([mine, other])
        defer { rig.folder.cleanUp() }

        let secret = try rig.secret([.log], machines: [mine.id])
        #expect(await rig.readLog(other.id, secret: secret).error?.code == -32001)
        #expect(rig.machines.calls.events.isEmpty)
    }

    @Test
    func aMachineWithAgentAccessOffIsNotReadAndOneThatDoesNotExistIsNamedSo() async throws {
        let closed = ControlMachine.fake("closed", access: false)
        let rig = try Rig([closed])
        defer { rig.folder.cleanUp() }

        let secret = try rig.secret([.log])
        #expect(await rig.readLog(closed.id, secret: secret).error?.code == -32003)
        #expect(await rig.readLog(UUID(), secret: secret).error?.code == -32002)
        #expect(rig.machines.calls.events.isEmpty)
    }

    @Test
    func aRefusalOfTheMachinesIsTheServicesRefusalWithItsSentence() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine], logOutcome: .refused("This machine is not a container."))
        defer { rig.folder.cleanUp() }

        let error = await rig.readLog(machine.id, secret: try rig.secret([.log])).error
        #expect(error?.code == -32004)
        #expect(error?.message == "Refused: This machine is not a container.")
    }

    @Test
    func aLongerTextThan64KiBComesBackAsItsLast64KiBAndTruncated() async throws {
        let machine = ControlMachine.fake("m")
        let text = String(repeating: "a", count: 100 * 1_024 - 3) + "end"
        let rig = try Rig([machine], logOutcome: .text(text, truncated: false))
        defer { rig.folder.cleanUp() }

        let answer = try rig.log(await rig.readLog(machine.id, secret: try rig.secret([.log])))
        #expect(answer.text.utf8.count == ControlLog.maxBytes)
        #expect(answer.text == String(text.suffix(ControlLog.maxBytes)))
        #expect(answer.truncated)
    }

    @Test
    func aTextThatFitsKeepsTheTruncatedFlagTheMachinesGave() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine], logOutcome: .text("short\n", truncated: true))
        defer { rig.folder.cleanUp() }

        let answer = try rig.log(await rig.readLog(machine.id, secret: try rig.secret([.log])))
        #expect(answer.text == "short\n" && answer.truncated, "the log held more than the machines returned")
    }

    // MARK: Where the end of a text is cut

    @Test
    func theEndIsCutForwardToTheStartOfACharacter() {
        let text = "x" + String(repeating: "é", count: 4)
        #expect(ControlLog.end(of: text, bytes: 100) == (text, false))
        #expect(ControlLog.end(of: text, bytes: 9) == (text, false), "exactly its size")
        #expect(ControlLog.end(of: text, bytes: 7).text == "ééé", "7 bytes begin inside a character")
        #expect(ControlLog.end(of: text, bytes: 7).cut)
        #expect(ControlLog.end(of: text, bytes: 6).text == "ééé")
        #expect(ControlLog.end(of: text, bytes: 1).text.isEmpty, "a character does not fit in a byte")
        #expect(ControlLog.end(of: "", bytes: 5) == ("", false))
    }
}

/// A 64 KiB tail of the characters that grow most when JSON escapes them travels the whole way, socket included, and arrives
/// as it was sent.
struct ControlLogLimitsTests {
    /// The end of a text made of `pieces` in turn, as the service would hold it: at most `ControlLog.maxBytes`.
    private func worstCase(_ pieces: [String]) -> String {
        var text = ""
        var index = 0
        while text.utf8.count < ControlLog.maxBytes + 100 {
            text += pieces[index % pieces.count]
            index += 1
        }
        return ControlLog.end(of: text, bytes: ControlLog.maxBytes).text
    }

    @Test(
        arguments: [
            ["\"", "\\", "/", "\n", "\t", "é", "€", "😀"],
            ["\"", "\n"],
            ["\u{01}", "\u{1F}"],
            ["😀"],
        ] as [[String]])
    func theTailRoundTripsExactlyAndItsAnswerFitsTheClientsLimit(pieces: [String]) async throws {
        let text = worstCase(pieces)
        #expect(text.utf8.count > ControlLog.maxBytes - 4)
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
        let secret = try store.create(name: "test", capabilities: [.log]).secret
        let machine = ControlMachine.fake("m")
        let machines = FakeMachines([machine], logOutcome: .text(text, truncated: true))
        let dispatcher = ControlDispatcher(tokens: store, machines: machines, report: { _ in })
        let params: [String: RPCValue] = ["token": .string(secret), "machine": .string(machine.id.uuidString)]

        let line = await dispatcher.answer(RPCRequest(id: .number(1), method: ControlMethod.log.rawValue, params: params)).encoded()
        #expect(line.count < ControlClient.defaultAnswerBytes, "the answer line is \(line.count) bytes")

        let connection = ControlConnection(dispatcher: dispatcher)
        let pair = try ControlClient.connectedPair()
        let client = pair.client
        let server = pair.server
        Task { await connection.serve(server) }
        defer { client.close() }
        let answer = try await runOnThread { Result { try client.call(ControlMethod.log.rawValue, params: params) } }.get()
        let result = try JSONDecoder().decode(ControlLog.self, from: try #require(answer.result))
        #expect(result == ControlLog(id: machine.id, text: text, truncated: true))
    }
}

/// The token file with the log capability in it.
struct ControlLogCapabilityTests {
    @Test
    func aTokensFileWithTheLogCapabilityIsReadAndItsLabelIsShown() throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let file = folder.url.appending(path: "tokens.json")
        let digest = String(repeating: "ab", count: 32)
        let json = """
            [{"id":"\(UUID().uuidString)","name":"reader","capabilities":["list","log"],"created":0,"digest":"\(digest)"}]
            """
        try Data(json.utf8).write(to: file)

        let store = try ControlTokenStore(file: file)
        #expect(store.all.first?.capabilities == [.list, .log])
        #expect(ControlCapability.log.rawValue == "log")
        #expect(ControlCapability.log.label == "Read a container's log")
        #expect(ControlMethod.log.capability == .log)
        #expect(ControlMethod.log.rawValue == "machines.log")
    }
}
