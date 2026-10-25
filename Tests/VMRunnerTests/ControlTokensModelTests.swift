import ControlProtocol
import Foundation
import Testing

@testable import VMRunner

/// The token list of Settings, on a store in a scratch folder.
@MainActor
struct ControlTokensModelTests {
    @Test
    func aNewTokenIsShownOnceListedWithoutItsSecretAndWorks() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "tokens.json")
        let store = try ControlTokenStore(file: file)
        let model = ControlTokensModel(store: { store })
        model.draftName = "agent"
        model.draftCapabilities = [.list, .start]
        model.create()

        let secret = try #require(model.newSecret)
        #expect(model.errorMessage == nil)
        #expect(model.draftName.isEmpty)
        let token = try #require(model.tokens.first)
        #expect(model.tokens.map(\.name) == ["agent"])
        #expect(ControlTokensModel.summary(of: token) == "List machines, Start")
        #expect(store.authenticate(secret)?.capabilities == [.list, .start])
        #expect(try !String(contentsOf: file, encoding: .utf8).contains(secret))

        model.newSecret = nil
        model.refresh()
        #expect(model.newSecret == nil, "the secret is not shown again")
    }

    @Test
    func theLogCapabilityCanBeTickedAndShowsItsLabel() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ControlTokenStore(file: folder.appending(path: "tokens.json"))
        let model = ControlTokensModel(store: { store })
        model.draftName = "reader"
        model.setCapability(.log, true)
        model.create()

        let token = try #require(model.tokens.first)
        #expect(token.capabilities.contains(.log))
        #expect(ControlTokensModel.summary(of: token) == "List machines, Read state, Read a container's log")
    }

    @Test
    func revokingRemovesTheTokenAndItsSecretFails() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ControlTokenStore(file: folder.appending(path: "tokens.json"))
        let model = ControlTokensModel(store: { store })
        model.draftName = "agent"
        model.create()
        let secret = try #require(model.newSecret)
        let token = try #require(model.tokens.first)

        model.revoke(token.id)
        #expect(model.tokens.isEmpty)
        #expect(store.authenticate(secret) == nil)
        model.revoke(token.id)
        #expect(model.errorMessage == "There is no such token.")
    }

    @Test
    func aTokenWithoutANameOrACapabilityIsRefusedWithAMessage() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ControlTokenStore(file: folder.appending(path: "tokens.json"))
        let model = ControlTokensModel(store: { store })
        model.draftName = "  "
        model.create()
        #expect(model.errorMessage == "A token needs a name.")
        model.draftName = "agent"
        model.setCapability(.list, false)
        model.setCapability(.state, false)
        #expect(model.draftCapabilities.isEmpty)
        model.create()
        #expect(model.errorMessage == "A token needs at least one capability.")
        #expect(model.newSecret == nil && model.tokens.isEmpty)
    }

    @Test
    func aTokenListThatCannotBeReadSaysWhy() {
        let model = ControlTokensModel(store: { throw ControlTokenError.unreadable(path: "/nowhere/tokens.json") })
        model.refresh()
        #expect(model.errorMessage == "The token list at /nowhere/tokens.json cannot be read.")
    }
}
