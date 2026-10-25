import Foundation

/// Checks each request against its token and the machine's agent access, then calls the machines (ADR-0056). Every refusal
/// goes to `report`, which the app logs.
public struct ControlDispatcher: Sendable {
    private let tokens: ControlTokenStore
    private let machines: any ControlMachines
    private let reportDenial: @Sendable (ControlDenial) -> Void

    public init(tokens: ControlTokenStore, machines: any ControlMachines, report: @escaping @Sendable (ControlDenial) -> Void) {
        self.tokens = tokens
        self.machines = machines
        reportDenial = report
    }

    /// Reports a refusal decided before a request is read (a client of another user).
    public func report(_ denial: ControlDenial) { reportDenial(denial) }

    /// The answer to `request`.
    public func answer(_ request: RPCRequest) async -> RPCResponse {
        guard let method = ControlMethod(rawValue: request.method) else {
            return RPCResponse(id: request.id, error: .methodNotFound)
        }
        let call: ControlCall
        switch ControlCall.read(method, request.params) {
        case .success(let read): call = read
        case .failure(let error): return RPCResponse(id: request.id, error: error)
        }
        switch authorize(call) {
        case .failure(let denial):
            report(denial)
            return RPCResponse(id: request.id, error: .notPermitted)
        case .success(let token):
            return await perform(call, token: token, id: request.id)
        }
    }

    private func authorize(_ call: ControlCall) -> Result<ControlToken, ControlDenial> {
        func denied(_ reason: ControlDenial.Reason, _ token: ControlToken? = nil) -> Result<ControlToken, ControlDenial> {
            .failure(ControlDenial(reason: reason, method: call.method, tokenID: token?.id, machine: call.machine))
        }
        guard let secret = call.token else { return denied(.noToken) }
        guard let token = tokens.authenticate(secret) else { return denied(.unknownToken) }
        guard token.capabilities.contains(call.method.capability) else { return denied(.missingCapability, token) }
        if let machine = call.machine, let allowed = token.machines, !allowed.contains(machine) {
            return denied(.outsideScope, token)
        }
        return .success(token)
    }

    private func perform(_ call: ControlCall, token: ControlToken, id: RPCID) async -> RPCResponse {
        let all = await machines.machines()
        guard let machineID = call.machine else {
            let visible = all.filter { $0.agentAccess && (token.machines?.contains($0.id) ?? true) }
            return Self.result(ControlMachineList(machines: visible), id: id)
        }
        guard let machine = all.first(where: { $0.id == machineID }) else {
            return RPCResponse(id: id, error: .noSuchMachine)
        }
        guard machine.agentAccess else {
            report(ControlDenial(reason: .agentAccessOff, method: call.method, tokenID: token.id, machine: machineID))
            return RPCResponse(id: id, error: .agentAccessOff)
        }
        switch call.method {
        case .start: return Self.outcome(await machines.start(machineID), of: machineID, id: id)
        case .stop: return Self.outcome(await machines.stop(machineID, force: call.force), of: machineID, id: id)
        case .log: return Self.logAnswer(await machines.log(machineID), of: machineID, id: id)
        case .screenshot: return Self.screenshot(await machines.screenshot(machineID), id: id)
        case .list, .state: return Self.result(machine, id: id)
        }
    }

    private static func screenshot(_ outcome: ControlScreenshotOutcome, id: RPCID) -> RPCResponse {
        switch outcome {
        case .done(let shot): result(shot, id: id)
        case .refused(let reason): RPCResponse(id: id, error: .refused.with(reason))
        }
    }

    /// The log's end, cut again to ``ControlLog/maxBytes`` whatever the adapter returned, or why it was not read.
    private static func logAnswer(_ outcome: ControlLogOutcome, of machine: UUID, id: RPCID) -> RPCResponse {
        switch outcome {
        case .text(let text, let truncated):
            let end = ControlLog.end(of: text, bytes: ControlLog.maxBytes)
            return result(ControlLog(id: machine, text: end.text, truncated: truncated || end.cut), id: id)
        case .refused(let reason):
            return RPCResponse(id: id, error: .refused.with(reason))
        }
    }

    private static func outcome(_ outcome: ControlOutcome, of machine: UUID, id: RPCID) -> RPCResponse {
        switch outcome {
        case .done(let state): result(ControlStateChange(id: machine, state: state), id: id)
        case .refused(let reason): RPCResponse(id: id, error: .refused.with(reason))
        }
    }

    private static func result(_ value: some Encodable, id: RPCID) -> RPCResponse {
        let encoder = JSONEncoder()
        // Base64 holds slashes, and an escaped one would cost a byte each of the answer's limited length.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = try? encoder.encode(value) else { return RPCResponse(id: id, error: .internalError) }
        return RPCResponse(id: id, result: json)
    }
}

/// The answer of `machines.list`.
struct ControlMachineList: Encodable {
    let machines: [ControlMachine]
}

/// The answer of `machines.start` and `machines.stop`.
struct ControlStateChange: Encodable {
    let id: UUID
    let state: ControlState
}

/// A request's params, checked against what its method takes.
struct ControlCall: Equatable {
    let method: ControlMethod
    var token: String?
    var machine: UUID?
    var force = false

    static func read(_ method: ControlMethod, _ params: [String: RPCValue]) -> Result<Self, RPCError> {
        guard Set(params.keys).isSubset(of: method.parameters) else {
            let allowed = method.parameters.sorted().joined(separator: ", ")
            return .failure(.invalidParams.with("\(method.rawValue) takes only \(allowed)"))
        }
        var call = Self(method: method)
        switch params["token"] {
        case .string(let secret): call.token = secret
        case .bool: return .failure(.invalidParams.with("token must be a string"))
        case nil: break
        }
        if method != .list {
            guard case .string(let text) = params["machine"], let machine = UUID(uuidString: text) else {
                return .failure(.invalidParams.with("machine must be a machine's id"))
            }
            call.machine = machine
        }
        switch params["force"] {
        case .bool(let force): call.force = force
        case .string: return .failure(.invalidParams.with("force must be true or false"))
        case nil: break
        }
        return .success(call)
    }
}
