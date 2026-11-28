import AemiJSONCore
public import AemiMCP
public import ControlProtocol
public import Foundation

/// The server side of the Model Context Protocol over stdio, read strictly: one JSON-RPC 2.0 message per line, an object
/// with `jsonrpc` "2.0", a method, a string or integer id (null is refused), and optional object params; no other member. A
/// batch is refused. It answers `initialize`, `ping` and `tools/list` itself and turns `tools/call` into a call of the
/// control service, one tool per control method. The protocol is AemiMCP's `MCPSyncServer`, configured this strictly.
public enum MCPServer {
    /// The protocol versions this server speaks, newest first. The client's version is answered when it is one of these,
    /// otherwise the newest, and the client decides whether to go on.
    public static let protocolVersions = ["2025-11-25", "2025-06-18"]
    /// The longest line read from the agent, in bytes.
    public static let lineBytes = 1 << 20
    /// The deepest nesting of objects and arrays a line may have; `initialize` needs about five. A deeper line is refused
    /// from a scan of its bytes, unparsed.
    public static let deepestNesting = 16

    private static let server = MCPSyncServer(
        configuration: MCPServerConfiguration(
            name: "vmrunner-control",
            title: "VMRunner control",
            version: "1.0.0",
            instructions: "Lists, reads, starts and stops VMRunner machines, reads a container's output log, and takes "
                + "screenshots of machines that use the custom GPU, through the app's local control service. Only machines "
                + "whose agent access is on are visible, and the token decides which tools may act.",
            protocolVersions: protocolVersions,
            requireProtocolVersion: true,
            maximumNesting: deepestNesting,
            rejectsUnknownMembers: true
        ),
        tools: MCPTool.allCases.map(\.definition),
        rejectUnknownToolAsInvalidParams: true
    )

    /// The answer to one line, ending with a newline; nil for a notification or an answer to a request this server never
    /// makes. A tool call is made by `call`, with the tool and its arguments, which are strings and booleans only.
    public static func answer(to line: Data, call: (MCPTool, [String: RPCValue]) -> MCPToolResult) -> Data? {
        let reply = server.handle(Array(line)) { name, arguments in
            guard let tool = MCPTool(rawValue: name) else { return .error("unknown tool \(name)") }
            guard let values = controlArguments(arguments) else {
                return .error("\(name) takes strings and booleans only")
            }
            return call(tool, values)
        }
        return reply.map { Data($0 + [UInt8(ascii: "\n")]) }
    }

    /// The arguments as control parameters, or nil when one is neither a string nor a boolean.
    private static func controlArguments(_ arguments: MCPToolArguments) -> [String: RPCValue]? {
        var values: [String: RPCValue] = [:]
        var valid = true
        arguments.json.forEachMember { key, value in
            if let text = value.string {
                values[key] = .string(text)
            } else if let flag = value.bool {
                values[key] = .bool(flag)
            } else {
                valid = false
            }
        }
        return valid ? values : nil
    }
}
