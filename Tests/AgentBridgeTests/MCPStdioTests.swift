import Foundation
import Testing

@testable import AgentBridge
@testable import ControlProtocol

/// A whole MCP session over pipes, each tool call made through the control library against a served connection: the
/// service's checks, its token store in a scratch folder and two machines held in memory. No app, no machine.
struct MCPStdioTests {
    /// One machine with agent access and one without; starts and stops answer at once.
    private struct TwoMachines: ControlMachines {
        let open = ControlMachine(id: UUID(), name: "open", guest: "linux", state: .stopped, agentAccess: true)
        let closed = ControlMachine(id: UUID(), name: "closed", guest: "linux", state: .stopped, agentAccess: false)

        func machines() async -> [ControlMachine] { [open, closed] }
        func start(_ id: UUID) async -> ControlOutcome { .done(.running) }
        func stop(_ id: UUID, force: Bool) async -> ControlOutcome { .done(force ? .stopped : .shuttingDown) }
        func log(_ id: UUID) async -> ControlLogOutcome { .text("the end of the log\n", truncated: true) }
    }

    private let machines = TwoMachines()

    /// Serves `input` (a newline ends each line) through a caller whose token holds `capabilities`, and returns the exit
    /// status and the answers. The answers' end is non-blocking: should they ever outgrow the pipe, the session fails instead
    /// of waiting forever for a reader that reads only once it ends.
    private func session(
        _ input: [String], capabilities: Set<ControlCapability> = Set(ControlCapability.allCases), lineBytes: Int = MCPServer.lineBytes,
        endsWithNewline: Bool = true
    ) async throws -> (status: Int32, answers: [[String: Any]]) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ControlTokenStore(file: folder.appending(path: "tokens.json"))
        let secret = try store.create(name: "agent", capabilities: capabilities).secret
        let connection = ControlConnection(dispatcher: ControlDispatcher(tokens: store, machines: machines, report: { _ in }))
        let caller = ControlCaller(token: secret) {
            let pair = try ControlClient.connectedPair()
            let server = pair.server
            Task { await connection.serve(server) }
            return pair.client
        }
        let toServer = Pipe()
        let fromServer = Pipe()
        let answers = fromServer.fileHandleForWriting.fileDescriptor
        _ = fcntl(answers, F_SETFL, fcntl(answers, F_GETFL) | O_NONBLOCK)
        var text = input.map { $0 + "\n" }.joined()
        if !endsWithNewline { text.removeLast() }
        try toServer.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try toServer.fileHandleForWriting.close()
        let reading = toServer.fileHandleForReading.fileDescriptor
        let status = await runOnThread { MCPStdio.serve(input: reading, output: answers, caller: caller, lineBytes: lineBytes) }
        try fromServer.fileHandleForWriting.close()
        let data = try fromServer.fileHandleForReading.readToEnd() ?? Data()
        let lines = data.split(separator: UInt8(ascii: "\n"))
        return (status, try lines.map { try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) })
    }

    private func call(_ id: Int, _ tool: String, _ arguments: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
    }

    /// The text and the error flag of a tool result.
    private func toolOutcome(_ answer: [String: Any]) throws -> (text: String, isError: Bool) {
        let result = try #require(answer["result"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (text, try #require(result["isError"] as? Bool))
    }

    @Test
    func aSessionInitializesListsItsToolsAndCallsEachControlMethod() async throws {
        let open = machines.open.id.uuidString
        let (status, answers) = try await session([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            call(3, "machines_list"),
            call(4, "machines_start", #"{"machine":"\#(open)"}"#),
            call(5, "machines_stop", #"{"machine":"\#(open)","force":true}"#),
        ])
        #expect(status == 0)
        #expect(answers.compactMap { $0["id"] as? Int } == [1, 2, 3, 4, 5], "the notification got no answer")
        let list = try toolOutcome(answers[2])
        #expect(!list.isError)
        let machines = try JSONDecoder().decode([String: [ControlMachine]].self, from: Data(list.text.utf8))
        #expect(machines["machines"] == [self.machines.open], "only the machine with agent access")
        #expect(try toolOutcome(answers[3]) == (#"{"id":"\#(open)","state":"running"}"#, false))
        #expect(try toolOutcome(answers[4]) == (#"{"id":"\#(open)","state":"stopped"}"#, false))
    }

    @Test
    func theLogToolAnswersTheServicesTextAndNeedsTheLogCapability() async throws {
        let open = machines.open.id.uuidString
        let (status, answers) = try await session(
            [call(1, "machines_log", #"{"machine":"\#(open)"}"#)], capabilities: [.log])
        #expect(status == 0)
        let outcome = try toolOutcome(answers[0])
        #expect(!outcome.isError)
        let log = try JSONDecoder().decode(ControlLog.self, from: Data(outcome.text.utf8))
        #expect(log == ControlLog(id: machines.open.id, text: "the end of the log\n", truncated: true))

        let (_, refused) = try await session([call(1, "machines_log", #"{"machine":"\#(open)"}"#)], capabilities: [.state])
        #expect(try toolOutcome(refused[0]) == ("error -32001: Not permitted", true))
    }

    @Test
    func aRefusalOfTheServiceIsAToolErrorWithItsCode() async throws {
        let closed = machines.closed.id.uuidString
        let open = machines.open.id.uuidString
        let (status, answers) = try await session(
            [call(1, "machines_start", #"{"machine":"\#(closed)"}"#), call(2, "machines_stop", #"{"machine":"\#(open)"}"#)],
            capabilities: [.start])
        #expect(status == 0)
        #expect(try toolOutcome(answers[0]) == ("error -32003: Agent access is off for this machine", true))
        #expect(try toolOutcome(answers[1]) == ("error -32001: Not permitted", true))
    }

    @Test
    func aServiceThatCannotBeReachedIsAToolError() async throws {
        let caller = ControlCaller(token: "vmrc_x", socket: "/tmp/vmr-no-such-control-\(UUID().uuidString.prefix(8)).sock")
        let answer = try #require(MCPStdio.answer(to: Data(call(1, "machines_list").utf8), caller: caller))
        let object = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
        let outcome = try toolOutcome(object)
        #expect(outcome.isError)
        #expect(outcome.text.contains("could not be used: nothing is serving"), "\(outcome.text)")
    }

    @Test
    func aLineLongerThanTheLimitIsRefusedAndEndsTheSession() async throws {
        let (status, answers) = try await session([String(repeating: "x", count: 100), call(2, "machines_list")], lineBytes: 64)
        #expect(status == 1)
        #expect(answers.count == 1, "nothing after the refusal")
        #expect((answers.first?["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test
    func aPartialLineAtTheEndOfTheInputIsDroppedAndTheSessionEndsCleanly() async throws {
        let (status, answers) = try await session(
            [#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#], endsWithNewline: false)
        #expect(status == 0)
        #expect(answers.compactMap { $0["id"] as? Int } == [1], "the last line lacks its newline, so it is not a message")
    }

    @Test
    func emptyLinesAreSkippedAndTheEndOfInputEndsTheSessionCleanly() async throws {
        let (status, answers) = try await session(["", #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, ""])
        #expect(status == 0)
        #expect(answers.count == 1)
    }
}
