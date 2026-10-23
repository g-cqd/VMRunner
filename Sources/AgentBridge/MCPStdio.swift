public import ControlProtocol
import Foundation
import GuestConsole

/// The MCP server over a pair of descriptors, standard input and output in `vmr control mcp`: one message per line in, one
/// answer per line out, in order. Each tool call is one call of the control service through `caller`, so a token, a socket
/// and the service's own checks decide what an agent may do.
public enum MCPStdio {
    /// Serves until the input ends (returns 0), or a line is longer than `lineBytes`, the input fails, or a non-blocking
    /// output stops taking answers for ten seconds (returns 1; a blocking output waits for its reader). A line longer than the
    /// limit is answered with an error before the end. A last line without its newline is dropped: a message ends with one.
    public static func serve(input: Int32, output: Int32, caller: ControlCaller, lineBytes: Int = MCPServer.lineBytes) -> Int32 {
        var buffer = LineBuffer(limit: lineBytes)
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            switch buffer.next() {
            case .line(let bytes):
                guard !bytes.isEmpty, let answer = answer(to: Data(bytes), caller: caller) else { continue }
                guard write(answer, to: output) else { return 1 }
                continue
            case .tooLong:
                let error = RPCError.invalidRequest.with("the message is longer than \(lineBytes) bytes")
                _ = write(RPCResponse(id: .null, error: error).encoded(), to: output)
                return 1
            case .needMore:
                break
            }
            switch ConsoleSocket.read(input, into: &chunk) {
            case .transferred(let count): buffer.append(chunk[..<count])
            case .wouldBlock: _ = ConsoleSocket.wait(input, milliseconds: 1_000)
            case .endOfStream: return 0
            case .failed: return 1
            }
        }
    }

    /// The answer line to one message; nil when it gets none.
    static func answer(to line: Data, caller: ControlCaller) -> Data? {
        switch MCPServer.action(for: line) {
        case .reply(let data):
            return data
        case .ignore:
            return nil
        case .callTool(let id, let tool, let arguments):
            return run(tool, id: id, arguments: arguments, caller: caller)
        }
    }

    /// Calls the tool's control method and answers with its result as text: the service's JSON result, or its error as a tool
    /// error that names the error's code, or why the service could not be reached.
    static func run(_ tool: MCPTool, id: RPCID, arguments: [String: RPCValue], caller: ControlCaller) -> Data {
        do {
            let answer = try caller.call(tool.method, params: arguments)
            if let code = answer.errorCode {
                return MCPServer.toolResult(id: id, text: "error \(code): \(answer.errorMessage ?? "refused")", isError: true)
            }
            let text = answer.result.flatMap { String(bytes: $0, encoding: .utf8) } ?? "null"
            return MCPServer.toolResult(id: id, text: text, isError: false)
        } catch {
            return MCPServer.toolResult(id: id, text: "the control service could not be used: \(error)", isError: true)
        }
    }

    private static func write(_ data: Data, to output: Int32) -> Bool {
        do {
            try ConsoleSocket.writeAll(output, Array(data), stallMilliseconds: 10_000)
            return true
        } catch {
            return false
        }
    }
}
