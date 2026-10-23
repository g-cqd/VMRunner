import ControlProtocol
import Foundation

/// What `vmr control status` found: whether something serves the socket and, with a token, whether the service accepts it.
struct ControlStatus {
    enum TokenCheck: String {
        case absent, unchecked, accepted, refused
    }

    let socket: String
    /// Whether a connection to the socket was accepted.
    var listening = false
    /// Why the service could not be used; nil when it answered.
    var failure: ToolError?
    var token = TokenCheck.absent
    /// How many machines the accepted token lists.
    var machines: Int?
    /// The service's error for a refused token.
    var refusal: String?

    /// Looks for the socket, connects to it, and with `token` lists the machines to check the token.
    static func check(socket: String, token: String?) -> Self {
        var status = Self(socket: socket)
        // Until the service has answered, a given token is unchecked, not absent.
        if token != nil { status.token = .unchecked }
        guard FileManager.default.fileExists(atPath: socket) else {
            status.failure = ToolError(
                "no socket at \(socket): the control service is off (VMRunner's Settings, Automation) or the app is not running",
                status: ControlExit.unavailable)
            return status
        }
        do {
            try ControlClient.connect(to: socket).close()
            status.listening = true
            guard let token else { return status }
            let answer = try ControlCaller(token: token, socket: socket).call(.list)
            if let code = answer.errorCode {
                status.token = .refused
                status.refusal = "\(answer.errorMessage ?? "refused") (\(code))"
            } else {
                status.token = .accepted
                let list = try? JSONDecoder().decode([String: [ControlMachine]].self, from: answer.result ?? Data())
                status.machines = list?["machines"]?.count
            }
        } catch {
            status.failure = ControlFailure.toolError(error, socket: socket)
        }
        return status
    }

    /// 0 when the service answered and the token, if any, was accepted.
    var exitStatus: Int32 {
        if let failure { return failure.status }
        return token == .refused ? ControlExit.notPermitted : 0
    }

    /// What a person reads.
    var lines: [String] {
        guard listening else { return [] }
        var lines = ["the control service is listening at \(socket)"]
        switch token {
        case .absent: lines.append("no token given (--token-file FILE or \(ControlTarget.tokenVariable)): not checked")
        case .unchecked: lines.append("a token was given but could not be checked")
        case .accepted: lines.append("the token is accepted: it lists \(machines ?? 0) machine(s)")
        case .refused: lines.append("the token is refused: \(refusal ?? "")")
        }
        return lines
    }

    /// The same as one JSON object, keys sorted.
    var json: String {
        var object: [String: Any] = ["socket": socket, "listening": listening, "token": token.rawValue]
        if let failure { object["problem"] = failure.message }
        if let machines { object["machines"] = machines }
        if let refusal { object["refusal"] = refusal }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
