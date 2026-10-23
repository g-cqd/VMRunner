import ControlProtocol
import Foundation

/// One `vmr control` call: made through the service, its error answer turned into a message and an exit status.
struct ControlInvocation {
    let socket: String
    let caller: ControlCaller

    /// The socket and the token of `target`; a missing token is a usage error.
    init(target: ControlCommand.TargetOptions) throws {
        let token = try target.requiredToken()
        socket = try target.socketPath()
        caller = ControlCaller(token: token, socket: socket)
    }

    /// The result of `method`, as the service wrote it (JSON, keys sorted). An error answer is thrown as a `ToolError` with
    /// its exit status, after it is printed as JSON when `json` is set.
    func result(_ method: ControlMethod, params: [String: RPCValue] = [:], json: Bool) throws -> Data {
        let answer: ControlAnswer
        do {
            answer = try caller.call(method, params: params)
        } catch {
            throw ControlFailure.toolError(error, socket: socket)
        }
        guard let code = answer.errorCode else { return answer.result ?? Data("null".utf8) }
        let message = answer.errorMessage ?? "refused"
        if json { Output.out(Self.errorJSON(code: code, message: message)) }
        throw ToolError("\(message) (\(code))", status: ControlFailure.status(forCode: code))
    }

    /// The machines the token lists.
    func machines(json: Bool) throws -> [ControlMachine] {
        try Self.decode([String: [ControlMachine]].self, from: try result(.list, json: json))["machines"] ?? []
    }

    /// `machine` itself when it is a machine's id; otherwise the id of the one machine of that name the token lists, which
    /// needs the list capability.
    func machineID(_ machine: String, json: Bool) throws -> String {
        if UUID(uuidString: machine) != nil { return machine }
        let named = try machines(json: json).filter { $0.name == machine }
        guard let only = named.first, named.count == 1 else {
            let reason = named.isEmpty ? "no machine named \(machine) has agent access" : "\(named.count) machines are named \(machine)"
            throw ToolError("\(reason); give the machine's id (vmr control list)", status: ControlExit.refused)
        }
        return only.id.uuidString
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ToolError("the control service's answer cannot be read", status: ControlExit.protocolError)
        }
    }

    static func text(_ data: Data) -> String { String(bytes: data, encoding: .utf8) ?? "" }

    /// One line per machine: id, state, guest and name.
    static func lines(listing machines: [ControlMachine]) -> [String] {
        guard !machines.isEmpty else { return ["no machine has agent access"] }
        return machines.map { machine in
            let state = machine.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            let guest = machine.guest.padding(toLength: 5, withPad: " ", startingAt: 0)
            return "\(machine.id.uuidString)  \(state)  \(guest)  \(machine.name)"
        }
    }

    private static func errorJSON(code: Int, message: String) -> String {
        let object: [String: Any] = ["error": ["code": code, "message": message]]
        return text((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data())
    }
}
