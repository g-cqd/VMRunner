public import Foundation
import Synchronization

/// Why a token could not be made, revoked or read.
public enum ControlTokenError: LocalizedError, Equatable, Sendable {
    case emptyName
    case nameTooLong(limit: Int)
    case noCapability
    case tooMany(limit: Int)
    case unknownToken
    case unreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A token needs a name."
        case .nameTooLong(let limit): "A token's name has at most \(limit) characters."
        case .noCapability: "A token needs at least one capability."
        case .tooMany(let limit): "There are already \(limit) tokens; revoke one first."
        case .unknownToken: "There is no such token."
        case .unreadable(let path): "The token list at \(path) cannot be read."
        }
    }
}

/// The tokens, kept as digests in one JSON file (mode 0600) in a folder the caller keeps private. A secret is returned once,
/// when its token is made, and never stored.
public final class ControlTokenStore: Sendable {
    public static let maximumTokens = 32
    public static let maximumNameLength = 64

    public let file: URL
    private let tokens: Mutex<[ControlToken]>

    /// Reads `file`. A missing file is an empty list; a file that does not decode is refused, not replaced.
    public init(file: URL) throws {
        self.file = file
        var stored: [ControlToken] = []
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                stored = try JSONDecoder().decode([ControlToken].self, from: Data(contentsOf: file))
            } catch {
                throw ControlTokenError.unreadable(path: file.path)
            }
        }
        tokens = Mutex(stored)
    }

    /// Every token, oldest first.
    public var all: [ControlToken] { tokens.withLock { $0 } }

    /// Makes a token and returns it with its secret, which is not kept: show it once.
    public func create(
        name: String, capabilities: Set<ControlCapability>, machines: [UUID]? = nil, now: Date = Date()
    ) throws -> (token: ControlToken, secret: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ControlTokenError.emptyName }
        guard trimmed.count <= Self.maximumNameLength else { throw ControlTokenError.nameTooLong(limit: Self.maximumNameLength) }
        guard !capabilities.isEmpty else { throw ControlTokenError.noCapability }
        let secret = ControlSecret.make()
        let token = ControlToken(
            id: UUID(), name: trimmed, capabilities: capabilities, machines: machines, created: now,
            digest: ControlSecret.digest(of: secret))
        try tokens.withLock { list in
            guard list.count < Self.maximumTokens else { throw ControlTokenError.tooMany(limit: Self.maximumTokens) }
            try write(list + [token])
            list.append(token)
        }
        return (token, secret)
    }

    /// Removes a token: its secret fails from the next request on.
    public func revoke(_ id: UUID) throws {
        try tokens.withLock { list in
            guard list.contains(where: { $0.id == id }) else { throw ControlTokenError.unknownToken }
            let kept = list.filter { $0.id != id }
            try write(kept)
            list = kept
        }
    }

    /// The token whose secret this is, or nil. The presented secret's digest is compared with every stored digest, each in
    /// constant time, whichever matches, so the time taken does not tell which tokens exist.
    public func authenticate(_ secret: String) -> ControlToken? {
        let presented = Array(ControlSecret.digest(of: secret).utf8)
        return tokens.withLock { list in
            var found: ControlToken?
            for token in list where ControlSecret.constantTimeEqual(presented, Array(token.digest.utf8)) {
                found = token
            }
            return found
        }
    }

    private func write(_ list: [ControlToken]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
