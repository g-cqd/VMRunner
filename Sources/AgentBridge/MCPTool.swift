public import ControlProtocol

/// The tools the MCP server offers: one for each method of the control service, with the same arguments.
public enum MCPTool: String, CaseIterable, Sendable {
    case list = "machines_list"
    case state = "machines_state"
    case start = "machines_start"
    case stop = "machines_stop"

    /// The control method the tool calls.
    public var method: ControlMethod {
        switch self {
        case .list: .list
        case .state: .state
        case .start: .start
        case .stop: .stop
        }
    }

    /// How `tools/list` describes it: a strict input schema (no other argument) and hints on what it changes.
    var definition: [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if self != .list { schema["required"] = ["machine"] }
        return ["name": rawValue, "title": title, "description": summary, "inputSchema": schema, "annotations": annotations]
    }

    private var title: String {
        switch self {
        case .list: "List machines"
        case .state: "Read a machine's state"
        case .start: "Start a machine"
        case .stop: "Stop a machine"
        }
    }

    private var summary: String {
        switch self {
        case .list: "Lists the VMRunner machines whose agent access is on, with their id, name, guest and state."
        case .state: "Reads one machine's state."
        case .start: "Starts a machine and answers once it runs or the start failed."
        case .stop: "Asks a machine's guest to shut down and answers at once; with force, cuts the power and answers once it is stopped."
        }
    }

    private var properties: [String: Any] {
        let machine: [String: Any] = ["type": "string", "description": "The machine's id, as machines_list gives it."]
        switch self {
        case .list: return [:]
        case .state, .start: return ["machine": machine]
        case .stop:
            let force: [String: Any] = [
                "type": "boolean", "description": "Cut the power at once instead of asking the guest to shut down.",
            ]
            return ["machine": machine, "force": force]
        }
    }

    private var annotations: [String: Any] {
        switch self {
        case .list, .state: ["readOnlyHint": true, "openWorldHint": false]
        case .start: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        case .stop: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false]
        }
    }
}
