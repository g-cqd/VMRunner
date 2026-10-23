import CryptoKit
public import Foundation

/// What a token allows. Each method needs one capability; later steps add screenshots, input and exec.
public enum ControlCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case list, state, start, stop

    /// How Settings names it.
    public var label: String {
        switch self {
        case .list: "List machines"
        case .state: "Read state"
        case .start: "Start"
        case .stop: "Stop"
        }
    }
}

/// A client's token as the store keeps it: never the secret, only its digest.
public struct ControlToken: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let capabilities: Set<ControlCapability>
    /// The machines the token may act on; nil for every machine whose agent access is on.
    public let machines: [UUID]?
    public let created: Date
    /// SHA-256 of the secret, in lowercase hex.
    let digest: String

    /// Capabilities are written in a fixed order, so the token file is the same on every save. Files written in any order
    /// still decode, since the set is decoded as before.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(capabilities.sorted { $0.rawValue < $1.rawValue }, forKey: .capabilities)
        try container.encodeIfPresent(machines, forKey: .machines)
        try container.encode(created, forKey: .created)
        try container.encode(digest, forKey: .digest)
    }
}

/// Making, hashing and comparing token secrets.
public enum ControlSecret {
    /// Every secret starts with it, so a secret that leaks into a file or a log is easy to recognise.
    public static let prefix = "vmrc_"

    /// A new secret: 256 bits from the system's cryptographically secure generator, as 64 hex digits after `prefix`.
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return prefix + hex(bytes)
    }

    /// The SHA-256 digest of `secret`, in lowercase hex: what the store keeps.
    public static func digest(of secret: String) -> String {
        hex(Array(SHA256.hash(data: Data(secret.utf8))))
    }

    /// Whether two byte strings are equal, in a time that depends on their length only: every byte is compared, so the time
    /// taken does not tell how much of a guess was right.
    public static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16) }.joined()
    }
}
