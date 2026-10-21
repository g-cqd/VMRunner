import Foundation

/// A property-list value, decoded without type erasure so entitlements compare by value.
enum PlistValue: Decodable, Equatable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([Self])
    case dictionary([String: Self])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .real(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Date.self) {
            self = .date(value)
        } else if let value = try? container.decode(Data.self) {
            self = .data(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .dictionary(try container.decode([String: Self].self))
        }
    }

    var description: String {
        switch self {
        case .bool(let value): "\(value)"
        case .integer(let value): "\(value)"
        case .real(let value): "\(value)"
        case .string(let value): "'\(value)'"
        case .data(let value): "<\(value.count) bytes>"
        case .date(let value): "\(value)"
        case .array(let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .dictionary(let values):
            "{" + values.keys.sorted().map { "\($0): \(values[$0]?.description ?? "")" }.joined(separator: ", ") + "}"
        }
    }
}

/// Reading and comparing entitlement property lists.
enum Entitlements {
    typealias Dictionary = [String: PlistValue]

    static let getTaskAllow = "com.apple.security.get-task-allow"

    /// The top-level dictionary of a property list; an empty input (a binary without entitlements) is an empty dictionary.
    static func parse(_ data: Data) throws -> Dictionary {
        guard !data.isEmpty else { return [:] }
        do {
            return try PropertyListDecoder().decode(Dictionary.self, from: data)
        } catch {
            throw ToolError("unreadable entitlements property list: \(error)")
        }
    }

    static func load(fileAt url: URL) throws -> Dictionary {
        guard let data = try? Data(contentsOf: url) else { throw ToolError("cannot read \(url.path)") }
        return try parse(data)
    }

    /// What is wrong with the entitlements read back from a signed bundle, compared with the file it was signed
    /// with: nothing added, nothing dropped, nothing changed, and never `get-task-allow` in a release build (it lets
    /// any process attach to this one).
    static func problems(effective: Dictionary, expected: Dictionary, isRelease: Bool) -> [String] {
        var problems: [String] = []
        if isRelease && effective[getTaskAllow] != nil {
            problems.append("get-task-allow is present in a release build")
        }
        for (key, actual) in effective.sorted(by: { $0.key < $1.key }) {
            guard let wanted = expected[key] else {
                problems.append("unexpected entitlement \(key) = \(actual)")
                continue
            }
            if actual != wanted {
                problems.append("entitlement \(key) is \(actual), expected \(wanted)")
            }
        }
        for key in expected.keys.sorted() where effective[key] == nil {
            problems.append("missing entitlement \(key)")
        }
        return problems
    }

    /// The keys of `base` that `hardened` drops or changes: the hardened file must stay a superset of the default one.
    static func lostByHardened(base: Dictionary, hardened: Dictionary) -> [String] {
        base.keys.sorted().filter { hardened[$0] != base[$0] }
    }
}
