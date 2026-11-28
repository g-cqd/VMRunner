import AemiJSONCore
import AemiMCP
public import ControlProtocol

/// The tools the MCP server offers: one for each method of the control service, with the same arguments.
public enum MCPTool: String, CaseIterable, Sendable {
    case list = "machines_list"
    case state = "machines_state"
    case log = "machines_log"
    case start = "machines_start"
    case stop = "machines_stop"
    case screenshot = "machines_screenshot"

    /// The control method the tool calls.
    public var method: ControlMethod {
        switch self {
        case .list: .list
        case .state: .state
        case .start: .start
        case .stop: .stop
        case .log: .log
        case .screenshot: .screenshot
        }
    }

    /// How `tools/list` describes it: a strict input schema (no other argument) and hints on what it changes.
    var definition: AemiMCP.MCPTool {
        AemiMCP.MCPTool(
            name: rawValue,
            title: title,
            description: summary,
            schema: MCPSchema.object(
                properties: properties,
                required: self == .list ? [] : ["machine"],
                additionalProperties: false
            ),
            annotations: annotations
        )
    }

    private var title: String {
        switch self {
        case .list: "List machines"
        case .state: "Read a machine's state"
        case .start: "Start a machine"
        case .stop: "Stop a machine"
        case .log: "Read a container's log"
        case .screenshot: "Take a screenshot of a machine"
        }
    }

    private var summary: String {
        switch self {
        case .list:
            "Lists the VMRunner machines whose agent access is on, with their id, name, guest, state and workload (vm or container)."
        case .state: "Reads one machine's state."
        case .start: "Starts a machine and answers once it runs or the start failed."
        case .stop:
            "Asks a machine's guest to shut down and answers at once; "
                + "with force, cuts the power (kills a container) and answers once it is stopped."
        case .log:
            "Reads the end of a container machine's output log, at most 64 KiB, as JSON with the text and whether there was more. "
                + "A virtual machine has no such log."
        case .screenshot:
            "Takes a PNG screenshot of a running machine's screen, at most 1280 pixels on its longest side. "
                + "Only machines that use the custom GPU have one to read."
        }
    }

    private var properties: KeyValuePairs<String, JSONValue> {
        let machine = MCPSchema.string("The machine's id, as machines_list gives it.")
        switch self {
        case .list: return [:]
        case .state, .start, .log, .screenshot: return ["machine": machine]
        case .stop:
            return ["machine": machine, "force": MCPSchema.boolean("Cut the power at once instead of asking the guest to shut down.")]
        }
    }

    private var annotations: MCPToolAnnotations {
        switch self {
        case .list, .state, .log, .screenshot: MCPToolAnnotations(readOnly: true, openWorld: false)
        case .start: MCPToolAnnotations(readOnly: false, destructive: false, idempotent: true, openWorld: false)
        case .stop: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true, openWorld: false)
        }
    }
}
