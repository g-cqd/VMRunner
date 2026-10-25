import AgentBridge
import ControlProtocol
import Foundation
import Testing

/// The MCP messages one by one: what each line is answered with, and which lines become a control call.
struct MCPServerTests {
    /// The answer to `line`, parsed; the test fails when the line is not answered.
    private func answer(_ line: String) throws -> [String: Any] {
        guard case .reply(let data) = MCPServer.action(for: Data(line.utf8)) else {
            Issue.record("no answer to \(line)")
            return [:]
        }
        #expect(data.last == UInt8(ascii: "\n"), "one answer per line")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func result(_ line: String) throws -> [String: Any] {
        let answer = try answer(line)
        return try #require(answer["result"] as? [String: Any], "a result in \(answer)")
    }

    private func errorCode(_ line: String) throws -> Int? {
        (try answer(line)["error"] as? [String: Any])?["code"] as? Int
    }

    @Test
    func initializeAnswersTheClientsVersionWhenThisServerSpeaksIt() throws {
        let line =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","#
            + #""capabilities":{"elicitation":{"form":{}}},"clientInfo":{"name":"test","version":"1"}}}"#
        let result = try result(line)
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "vmrunner-control")
    }

    @Test
    func initializeAnswersTheNewestVersionForAnotherOne() throws {
        let result = try result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-01-01"}}"#)
        #expect(result["protocolVersion"] as? String == MCPServer.protocolVersions.first)
        #expect(MCPServer.protocolVersions.first == "2025-11-25")
    }

    @Test
    func initializeWithoutAVersionIsInvalidParams() throws {
        #expect(try errorCode(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#) == -32602)
    }

    @Test
    func pingIsAnsweredWithAnEmptyResultAndTheSameID() throws {
        let answer = try answer(#"{"jsonrpc":"2.0","id":"a-1","method":"ping"}"#)
        #expect(answer["id"] as? String == "a-1")
        #expect((answer["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test
    func theToolsAreTheFiveControlMethodsWithStrictSchemas() throws {
        let tools = try #require(try result(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["tools"] as? [[String: Any]])
        #expect(
            tools.compactMap { $0["name"] as? String } == [
                "machines_list", "machines_state", "machines_log", "machines_start", "machines_stop",
            ])
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
        }
        let stop = try #require(tools.last?["inputSchema"] as? [String: Any])
        #expect(((stop["properties"] as? [String: Any])?["force"] as? [String: Any])?["type"] as? String == "boolean")
        #expect(stop["required"] as? [String] == ["machine"])
        #expect((tools.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        #expect((tools.last?["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true)
    }

    @Test
    func theLogToolReadsAndChangesNothing() throws {
        let tools = try #require(try result(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["tools"] as? [[String: Any]])
        let log = try #require(tools.first { $0["name"] as? String == "machines_log" })
        let annotations = try #require(log["annotations"] as? [String: Any])
        #expect(annotations["readOnlyHint"] as? Bool == true && annotations["openWorldHint"] as? Bool == false)
        let schema = try #require(log["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["machine"] && schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Array(properties.keys) == ["machine"])
        #expect(MCPTool.log.method == .log)
    }

    @Test
    func aToolCallBecomesACallOfItsControlMethod() {
        let line =
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"machines_stop","arguments":{"machine":"m","force":true}}}"#
        let expected = MCPAction.callTool(id: .number(3), tool: .stop, arguments: ["machine": .string("m"), "force": .bool(true)])
        #expect(MCPServer.action(for: Data(line.utf8)) == expected)
        #expect(MCPTool.stop.method == .stop)
    }

    @Test
    func anUnknownToolIsInvalidParams() throws {
        #expect(try errorCode(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"exec"}}"#) == -32602)
    }

    @Test
    func anArgumentThatIsNeitherAStringNorABooleanIsAToolError() throws {
        let line = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"machines_state","arguments":{"machine":7}}}"#
        let result = try result(line)
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
    }

    @Test
    func aNotificationAndAnAnswerAreNotAnswered() {
        #expect(MCPServer.action(for: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == .ignore)
        #expect(MCPServer.action(for: Data(#"{"jsonrpc":"2.0","id":9,"result":{}}"#.utf8)) == .ignore)
    }

    @Test(arguments: [
        ("{not json", -32700),
        (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, -32600),
        (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":18446744073709551615,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":1,"method":""}"#, -32600),
        (#"{"jsonrpc":"2.0","id":1,"method":"ping","extra":1}"#, -32600),
        (#"{"jsonrpc":"2.0","id":1}"#, -32600),
        (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[1]}"#, -32602),
        (#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#, -32601),
    ])
    func aMalformedOrUnknownMessageIsRefused(line: String, code: Int) throws {
        #expect(try errorCode(line) == code)
    }

    @Test
    func aMessageNestedTooDeeplyIsRefusedUnparsed() throws {
        let deep = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        #expect(try errorCode(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"# + deep + "}}") == -32600)
    }

    @Test(arguments: [(16, false), (17, true)])
    func aMessageNestedSixteenLevelsDeepIsReadAndSeventeenIsRefused(depth: Int, refused: Bool) throws {
        // The message and its params object are two levels; the arrays inside `x` make up the rest.
        let arrays = String(repeating: "[", count: depth - 2) + String(repeating: "]", count: depth - 2)
        let line = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"# + arrays + "}}"
        if refused {
            #expect(try errorCode(line) == -32600)
        } else {
            #expect(try answer(line)["result"] != nil)
        }
    }

    @Test
    func aToolResultCarriesItsTextAndWhetherItFailed() throws {
        let data = MCPServer.toolResult(id: .string("x"), text: "error -32003: off", isError: true)
        let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect((result["content"] as? [[String: Any]])?.first?["text"] as? String == "error -32003: off")
    }
}
