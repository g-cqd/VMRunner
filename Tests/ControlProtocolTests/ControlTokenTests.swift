import Foundation
import Testing

@testable import ControlProtocol

/// Secrets are 256 random bits; only their SHA-256 digest is kept; digests are compared in constant time.
struct ControlSecretTests {
    @Test
    func aSecretIs256RandomBitsInHexAfterThePrefix() {
        let secret = ControlSecret.make()
        #expect(secret.hasPrefix("vmrc_"))
        let digits = secret.dropFirst(ControlSecret.prefix.count)
        #expect(digits.count == 64)
        #expect(digits.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(ControlSecret.make() != secret)
    }

    @Test
    func theDigestIsSHA256InLowercaseHex() {
        #expect(ControlSecret.digest(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ControlSecret.digest(of: "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test
    func theConstantTimeComparisonSaysEqualOnlyForEqualBytes() {
        let bytes: [UInt8] = [1, 2, 3, 4]
        #expect(ControlSecret.constantTimeEqual(bytes, [1, 2, 3, 4]))
        #expect(!ControlSecret.constantTimeEqual(bytes, [0, 2, 3, 4]), "the first byte differs")
        #expect(!ControlSecret.constantTimeEqual(bytes, [1, 2, 3, 5]), "the last byte differs")
        #expect(!ControlSecret.constantTimeEqual(bytes, [1, 2, 3]), "a shorter string")
        #expect(ControlSecret.constantTimeEqual([], []))
    }
}

/// The store: a token shown once, kept as a digest in a private file, found by its secret, gone once revoked.
struct ControlTokenStoreTests {
    @Test
    func aTokenIsShownOnceAndOnlyItsDigestIsStoredInAPrivateFile() throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let file = folder.url.appending(path: "tokens.json")
        let store = try ControlTokenStore(file: file)
        let made = try store.create(name: "  agent  ", capabilities: [.list, .state])
        #expect(made.token.name == "agent")
        #expect(store.authenticate(made.secret) == made.token)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(made.secret), "the secret is never written")
        #expect(text.contains(ControlSecret.digest(of: made.secret)))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test
    func aWrongSecretMatchesNothing() throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
        let made = try store.create(name: "agent", capabilities: [.list])
        #expect(store.authenticate(ControlSecret.make()) == nil)
        #expect(store.authenticate("") == nil)
        #expect(store.authenticate(made.secret + "0") == nil)
        #expect(store.authenticate(String(made.secret.dropLast())) == nil)
    }

    @Test
    func tokensSurviveAReloadAndARevokedOneFailsAtOnceAndAfterAReload() throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let file = folder.url.appending(path: "tokens.json")
        let store = try ControlTokenStore(file: file)
        let first = try store.create(name: "one", capabilities: [.list])
        let second = try store.create(name: "two", capabilities: [.start], machines: [UUID()])
        let reloaded = try ControlTokenStore(file: file)
        #expect(reloaded.all == store.all)
        #expect(reloaded.authenticate(second.secret)?.machines == second.token.machines)

        try store.revoke(first.token.id)
        #expect(store.authenticate(first.secret) == nil)
        #expect(store.authenticate(second.secret) == second.token)
        #expect(try ControlTokenStore(file: file).authenticate(first.secret) == nil)
        #expect(throws: ControlTokenError.unknownToken) { try store.revoke(first.token.id) }
    }

    @Test
    func badNamesAnEmptyCapabilitySetAndAFullListAreRefused() throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
        #expect(throws: ControlTokenError.emptyName) { _ = try store.create(name: "  ", capabilities: [.list]) }
        #expect(throws: ControlTokenError.nameTooLong(limit: 64)) {
            _ = try store.create(name: String(repeating: "n", count: 65), capabilities: [.list])
        }
        #expect(throws: ControlTokenError.noCapability) { _ = try store.create(name: "n", capabilities: []) }
        for index in 0..<ControlTokenStore.maximumTokens { _ = try store.create(name: "t\(index)", capabilities: [.list]) }
        #expect(throws: ControlTokenError.tooMany(limit: 32)) { _ = try store.create(name: "one more", capabilities: [.list]) }
        #expect(store.all.count == 32)
    }

    @Test
    func capabilitiesAreWrittenInAFixedOrderSoTheFileIsStable() throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let file = folder.url.appending(path: "tokens.json")
        let store = try ControlTokenStore(file: file)
        _ = try store.create(name: "agent", capabilities: [.stop, .list, .start])
        let text = try String(contentsOf: file, encoding: .utf8)
        let list = try #require(text.range(of: "\"list\""))
        let start = try #require(text.range(of: "\"start\""))
        let stop = try #require(text.range(of: "\"stop\""))
        #expect(list.lowerBound < start.lowerBound && start.lowerBound < stop.lowerBound)
        #expect(try ControlTokenStore(file: file).all.first?.capabilities == [.stop, .list, .start])
    }

    @Test
    func aFileThatDoesNotDecodeIsRefusedAndKept() throws {
        let folder = try ScratchFolder()
        defer { folder.cleanUp() }
        let file = folder.url.appending(path: "tokens.json")
        try Data("not json".utf8).write(to: file)
        #expect(throws: ControlTokenError.unreadable(path: file.path)) { _ = try ControlTokenStore(file: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
    }
}
