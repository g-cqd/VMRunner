public import ControlProtocol
public import Foundation

/// What to do with one line from the agent.
public enum MCPAction: Equatable, Sendable {
    /// Send this line; it ends with a newline.
    case reply(Data)
    /// Call the tool's control method with `arguments`, then answer the request `id` with the result.
    case callTool(id: RPCID, tool: MCPTool, arguments: [String: RPCValue])
    /// Send nothing: a notification, or an answer to a request this server never makes.
    case ignore
}

/// The server side of the Model Context Protocol over stdio, read strictly: one JSON-RPC 2.0 message per line, an object
/// with `jsonrpc` "2.0", a method, a string or integer id (null is refused), and optional object params; no other member. A
/// batch is refused. It answers `initialize`, `ping` and `tools/list` itself and turns `tools/call` into a call of the
/// control service, one tool per control method.
public enum MCPServer {
    /// The protocol versions this server speaks, newest first. The client's version is answered when it is one of these,
    /// otherwise the newest, and the client decides whether to go on.
    public static let protocolVersions = ["2025-11-25", "2025-06-18"]
    /// The longest line read from the agent, in bytes.
    public static let lineBytes = 1 << 20
    /// The deepest nesting of objects and arrays a line may have; `initialize` needs about five. The system parser recurses
    /// with the nesting, so a deeper line is refused unparsed.
    public static let deepestNesting = 16

    private static let requestMembers: Set<String> = ["jsonrpc", "id", "method", "params"]

    /// What one line asks for.
    public static func action(for line: Data) -> MCPAction {
        switch parse(line) {
        case .refused(let response): .reply(response.encoded())
        case .ignored: .ignore
        case .request(let id, let method, let params): answer(method, id: id, params: params)
        }
    }

    /// The line that answers the request `id` with a tool's result: `text` as its one text content, and `isError` set when
    /// the tool failed.
    public static func toolResult(id: RPCID, text: String, isError: Bool) -> Data {
        reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
    }

    private enum Parsed {
        case request(RPCID, String, [String: Any])
        case ignored
        case refused(RPCResponse)
    }

    private static func parse(_ line: Data) -> Parsed {
        guard RPCMessage.nesting(of: line) <= deepestNesting else {
            return .refused(RPCResponse(id: .null, error: .invalidRequest.with("the message is nested too deeply")))
        }
        guard let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else {
            return .refused(RPCResponse(id: .null, error: .parseError))
        }
        if object is [Any] {
            return .refused(RPCResponse(id: .null, error: .invalidRequest.with("batches are not supported")))
        }
        guard let fields = object as? [String: Any], fields["jsonrpc"] as? String == "2.0" else {
            return .refused(RPCResponse(id: .null, error: .invalidRequest.with(#"a message is an object with jsonrpc "2.0""#)))
        }
        guard let method = fields["method"] else {
            // An answer to a request: this server makes none, so there is nothing to match it with.
            let isAnswer = fields["id"] != nil && (fields["result"] != nil || fields["error"] != nil)
            return isAnswer ? .ignored : .refused(RPCResponse(id: .null, error: .invalidRequest.with("a request needs a method")))
        }
        return request(fields, method: method)
    }

    private static func request(_ fields: [String: Any], method: Any) -> Parsed {
        guard let method = method as? String, !method.isEmpty else {
            return .refused(RPCResponse(id: .null, error: .invalidRequest.with("method must be a non-empty string")))
        }
        // A notification is never answered, and none asks this server for anything.
        guard let rawID = fields["id"] else { return .ignored }
        guard let id = requestID(rawID) else {
            return .refused(RPCResponse(id: .null, error: .invalidRequest.with("the id must be a string or an integer")))
        }
        guard Set(fields.keys).isSubset(of: requestMembers) else {
            return .refused(RPCResponse(id: id, error: .invalidRequest.with("the only members are jsonrpc, id, method and params")))
        }
        guard let params = (fields["params"] ?? [String: Any]()) as? [String: Any] else {
            return .refused(RPCResponse(id: id, error: .invalidParams.with("params must be an object")))
        }
        return .request(id, method, params)
    }

    private static func answer(_ method: String, id: RPCID, params: [String: Any]) -> MCPAction {
        switch method {
        case "initialize":
            guard let version = params["protocolVersion"] as? String else {
                return .reply(RPCResponse(id: id, error: .invalidParams.with("initialize needs a protocolVersion")).encoded())
            }
            return .reply(reply(id, initializeResult(requested: version)))
        case "ping":
            return .reply(reply(id, [:]))
        case "tools/list":
            return .reply(reply(id, ["tools": MCPTool.allCases.map(\.definition)]))
        case "tools/call":
            return toolCall(id: id, params: params)
        default:
            return .reply(RPCResponse(id: id, error: .methodNotFound).encoded())
        }
    }

    private static func toolCall(id: RPCID, params: [String: Any]) -> MCPAction {
        guard let name = params["name"] as? String else {
            return .reply(RPCResponse(id: id, error: .invalidParams.with("tools/call needs a tool name")).encoded())
        }
        guard let tool = MCPTool(rawValue: name) else {
            return .reply(RPCResponse(id: id, error: .invalidParams.with("unknown tool")).encoded())
        }
        guard let raw = (params["arguments"] ?? [String: Any]()) as? [String: Any] else {
            return .reply(toolResult(id: id, text: "arguments must be an object", isError: true))
        }
        var arguments: [String: RPCValue] = [:]
        for (key, value) in raw {
            guard let parsed = argument(value) else {
                return .reply(toolResult(id: id, text: "\(name) takes strings and booleans only", isError: true))
            }
            arguments[key] = parsed
        }
        return .callTool(id: id, tool: tool, arguments: arguments)
    }

    private static func initializeResult(requested: String) -> [String: Any] {
        [
            "protocolVersion": protocolVersions.contains(requested) ? requested : protocolVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "vmrunner-control", "title": "VMRunner control", "version": "1.0.0"],
            "instructions": "Lists, reads, starts and stops VMRunner machines, and reads a container's output log, through the "
                + "app's local control service. Only machines whose agent access is on are visible, and the token decides which "
                + "tools may act.",
        ]
    }

    /// A JSON string or boolean; nothing else is a control parameter.
    private static func argument(_ raw: Any) -> RPCValue? {
        if let number = raw as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : nil
        }
        return (raw as? String).map(RPCValue.string)
    }

    /// A string, or a whole number that is not a boolean and fits an `Int` (an id above that would be answered with another
    /// number). MCP forbids a null id.
    private static func requestID(_ raw: Any) -> RPCID? {
        if let text = raw as? String { return .string(text) }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number),
            String(number.intValue) == number.stringValue
        else {
            return nil
        }
        return .number(number.intValue)
    }

    private static func reply(_ id: RPCID, _ result: [String: Any]) -> Data {
        guard let json = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
            return RPCResponse(id: id, error: .internalError).encoded()
        }
        return RPCResponse(id: id, result: json).encoded()
    }
}
