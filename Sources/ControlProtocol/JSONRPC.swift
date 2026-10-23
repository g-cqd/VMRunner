public import Foundation

/// A request's id: a string, an integer or null (JSON-RPC 2.0). An answer carries the id of its request.
public enum RPCID: Hashable, Sendable {
    case number(Int)
    case string(String)
    case null

    /// The id as JSON text.
    var json: Data {
        switch self {
        case .number(let value): Data(String(value).utf8)
        case .string(let text): RPCResponse.quoted(text)
        case .null: Data("null".utf8)
        }
    }
}

/// A member of a request's `params`. The control methods take strings and booleans only, so nothing else is accepted.
public enum RPCValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
}

/// A request that expects an answer.
public struct RPCRequest: Equatable, Sendable {
    public let id: RPCID
    public let method: String
    public let params: [String: RPCValue]

    public init(id: RPCID, method: String, params: [String: RPCValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC error object: the standard codes, and the control service's own (-32001 to -32005, ADR-0056).
public struct RPCError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    // swift-format-ignore: DontRepeatTypeInStaticProperties
    public static let parseError = Self(code: -32700, message: "Parse error")
    public static let invalidRequest = Self(code: -32600, message: "Invalid Request")
    public static let methodNotFound = Self(code: -32601, message: "Method not found")
    public static let invalidParams = Self(code: -32602, message: "Invalid params")
    // swift-format-ignore: DontRepeatTypeInStaticProperties
    public static let internalError = Self(code: -32603, message: "Internal error")
    public static let notPermitted = Self(code: -32001, message: "Not permitted")
    public static let noSuchMachine = Self(code: -32002, message: "No such machine")
    public static let agentAccessOff = Self(code: -32003, message: "Agent access is off for this machine")
    public static let refused = Self(code: -32004, message: "Refused")
    public static let timedOut = Self(code: -32005, message: "Timed out; the operation may still finish")

    /// The same error with a detail after its message.
    public func with(_ detail: String) -> Self { Self(code: code, message: "\(message): \(detail)") }
}

/// An answer: the request's id and either a result or an error.
public struct RPCResponse: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        /// The `result` member, already encoded as JSON, without a newline.
        case result(Data)
        case error(RPCError)
    }

    public let id: RPCID
    public let body: Body

    public init(id: RPCID, result: Data) {
        self.id = id
        body = .result(result)
    }

    public init(id: RPCID, error: RPCError) {
        self.id = id
        body = .error(error)
    }

    /// The error, when this answer is one.
    public var error: RPCError? {
        if case .error(let error) = body { error } else { nil }
    }

    /// The answer as one line of JSON, ending with a newline.
    public func encoded() -> Data {
        var line = Data(#"{"id":"#.utf8)
        line.append(id.json)
        line.append(Data(#","jsonrpc":"2.0","#.utf8))
        switch body {
        case .result(let json):
            line.append(Data(#""result":"#.utf8))
            line.append(json)
        case .error(let error):
            line.append(Data(#""error":{"code":"#.utf8))
            line.append(Data(String(error.code).utf8))
            line.append(Data(#","message":"#.utf8))
            line.append(Self.quoted(error.message))
            line.append(Data("}".utf8))
        }
        line.append(Data("}\n".utf8))
        return line
    }

    /// `text` as a JSON string, its quotes and escapes included.
    static func quoted(_ text: String) -> Data {
        (try? JSONEncoder().encode(text)) ?? Data(#""""#.utf8)
    }
}

/// What one line from a client is.
public enum RPCParse: Equatable, Sendable {
    case request(RPCRequest)
    /// A request without an id. JSON-RPC forbids answering it, and the control service does not run it either.
    case notification(method: String)
    /// Not a valid request, with the answer to send at once.
    case invalid(RPCResponse)
}

/// Reads JSON-RPC 2.0 requests strictly: an object with `jsonrpc` "2.0", a non-empty `method` string, an optional `id` (a
/// string, an integer or null) and optional `params` (an object of strings and booleans), and no other member. A batch (an
/// array) is refused with the standard Invalid Request error.
public enum RPCMessage {
    private static let members: Set<String> = ["jsonrpc", "id", "method", "params"]
    /// The deepest nesting of objects and arrays a line may have; a request needs two. The system parser recurses with the
    /// nesting and overflows the stack of a worker thread well below its own limit, so a deeper line is refused unparsed.
    private static let deepestNesting = 8

    public static func parse(_ line: Data) -> RPCParse {
        guard nesting(of: line) <= deepestNesting else {
            return .invalid(RPCResponse(id: .null, error: .invalidRequest.with("the request is nested too deeply")))
        }
        guard let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else {
            return .invalid(RPCResponse(id: .null, error: .parseError))
        }
        if object is [Any] {
            return .invalid(RPCResponse(id: .null, error: .invalidRequest.with("batches are not supported")))
        }
        guard let fields = object as? [String: Any] else {
            return .invalid(RPCResponse(id: .null, error: .invalidRequest.with("a request is a JSON object")))
        }
        var replyID = RPCID.null
        if let raw = fields["id"] {
            guard let parsed = id(from: raw) else {
                return .invalid(RPCResponse(id: .null, error: .invalidRequest.with("the id must be a string, an integer or null")))
            }
            replyID = parsed
        }
        return request(from: fields, id: replyID, isNotification: fields["id"] == nil)
    }

    /// The deepest nesting of `{` and `[` in `line`, outside strings.
    public static func nesting(of line: Data) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in line {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                deepest = max(deepest, depth)
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth = max(0, depth - 1)
            default: break
            }
        }
        return deepest
    }

    private static func request(from fields: [String: Any], id: RPCID, isNotification: Bool) -> RPCParse {
        guard fields["jsonrpc"] as? String == "2.0" else {
            return .invalid(RPCResponse(id: id, error: .invalidRequest.with(#"jsonrpc must be "2.0""#)))
        }
        guard let method = fields["method"] as? String, !method.isEmpty else {
            return .invalid(RPCResponse(id: id, error: .invalidRequest.with("method must be a non-empty string")))
        }
        guard Set(fields.keys).isSubset(of: members) else {
            return .invalid(RPCResponse(id: id, error: .invalidRequest.with("the only members are jsonrpc, id, method and params")))
        }
        if isNotification { return .notification(method: method) }
        switch params(from: fields["params"]) {
        case .success(let params): return .request(RPCRequest(id: id, method: method, params: params))
        case .failure(let error): return .invalid(RPCResponse(id: id, error: error))
        }
    }

    private static func params(from raw: Any?) -> Result<[String: RPCValue], RPCError> {
        guard let raw else { return .success([:]) }
        guard let object = raw as? [String: Any] else { return .failure(.invalidParams.with("params must be an object")) }
        var params: [String: RPCValue] = [:]
        for (key, value) in object {
            guard let parsed = Self.value(from: value) else {
                return .failure(.invalidParams.with("params hold strings and booleans only"))
            }
            params[key] = parsed
        }
        return .success(params)
    }

    private static func id(from raw: Any) -> RPCID? {
        if raw is NSNull { return .null }
        if let text = raw as? String { return .string(text) }
        // A number written with a fraction or an exponent is not an integer id; a whole one keeps every digit.
        guard !isBoolean(raw), let number = raw as? NSNumber, !CFNumberIsFloatType(number as CFNumber) else { return nil }
        return .number(number.intValue)
    }

    private static func value(from raw: Any) -> RPCValue? {
        if isBoolean(raw) { return (raw as? Bool).map(RPCValue.bool) }
        return (raw as? String).map(RPCValue.string)
    }

    /// JSON `true` and `false` arrive as numbers that are Booleans underneath; this tells them from 0 and 1.
    private static func isBoolean(_ raw: Any) -> Bool {
        CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID()
    }
}
