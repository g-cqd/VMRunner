import Foundation
import Testing

@testable import VMRunner

@MainActor
struct NetworkPolicyModelTests {
    /// The model refers to its library without owning it, so the rig holds both; tests keep the rig alive to their end
    /// through the `defer` that removes `directory`.
    private struct Rig {
        let model: NetworkPolicyModel
        let library: VMLibrary
        let id: UUID
        let directory: URL
    }

    private func makeModel() throws -> Rig {
        let directory = try scratchDirectory()
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        var config = VMConfig.new(name: "m", guest: .linux)
        config.networkMode = .filtered
        try library.add(config)
        return Rig(model: NetworkPolicyModel(id: config.id, library: library), library: library, id: config.id, directory: directory)
    }

    @Test func aTypedRuleIsAddedInCanonicalFormAndTheFieldIsCleared() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        model.drafts[.blockedDomains] = "  Evil.COM "

        #expect(model.canAdd(to: .blockedDomains))
        model.add(to: .blockedDomains)

        #expect(model.rules(in: .blockedDomains) == ["evil.com"])
        #expect(rig.library.machine(rig.id)?.networkPolicy.blockedDomains.count == 1)
        #expect(model.drafts[.blockedDomains]?.isEmpty == true)
        #expect(model.problem(for: .blockedDomains) == nil)
    }

    @Test func aBadRuleShowsTheEnginesMessageAndChangesNothing() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        model.drafts[.blockedPorts] = "70000"

        #expect(!model.canAdd(to: .blockedPorts))
        #expect(model.problem(for: .blockedPorts) == NetworkPolicyError.invalidPort("70000").errorDescription)
        model.add(to: .blockedPorts)

        #expect(rig.library.machine(rig.id)?.networkPolicy == NetworkPolicy())
        #expect(model.drafts[.blockedPorts] == "70000", "the text stays so it can be corrected")
    }

    @Test func eachListHasItsOwnFieldAndItsOwnError() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        model.drafts[.blockedAddresses] = "10.0.0.0/33"
        model.drafts[.blockedDomains] = "example.com"

        #expect(model.problem(for: .blockedAddresses) != nil)
        #expect(model.problem(for: .blockedDomains) == nil)
        #expect(model.canAdd(to: .blockedDomains))
        #expect(!model.canAdd(to: .blockedAddresses))
    }

    @Test func anEmptyFieldIsNeitherAProblemNorAddable() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        for text in [nil, "", "   "] {
            model.drafts[.allowedDomains] = text
            #expect(model.problem(for: .allowedDomains) == nil)
            #expect(!model.canAdd(to: .allowedDomains))
        }
    }

    @Test func removeDeletesTheRuleAtThatPosition() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        for port in ["22", "23", "25"] {
            model.drafts[.blockedPorts] = port
            model.add(to: .blockedPorts)
        }

        model.remove(at: 0, from: .blockedPorts)

        #expect(model.rules(in: .blockedPorts) == ["23", "25"])
        #expect(model.count(in: .blockedPorts) == 2)
    }

    @Test func aListStopsGrowingAtTheLimit() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        for port in 1...EditorLimits.maxRulesPerList {
            model.drafts[.blockedPorts] = "\(port)"
            model.add(to: .blockedPorts)
        }
        #expect(model.count(in: .blockedPorts) == EditorLimits.maxRulesPerList)

        model.drafts[.blockedPorts] = "9999"
        #expect(!model.canAdd(to: .blockedPorts))
        #expect(model.problem(for: .blockedPorts)?.contains("\(EditorLimits.maxRulesPerList)") == true)
        model.add(to: .blockedPorts)
        #expect(model.count(in: .blockedPorts) == EditorLimits.maxRulesPerList)
    }

    @Test func anAllowListWithNothingAllowedWarnsThatTheGuestHasNoNetwork() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        #expect(model.allowListWarning == nil, "a block list needs no allowed destinations")

        var config = try #require(rig.library.machine(rig.id))
        config.networkPolicy.mode = .allowListed
        rig.library.update(config)
        #expect(model.allowListWarning?.contains("Nothing is allowed") == true)

        model.drafts[.allowedConnections] = "github.com:443"
        model.add(to: .allowedConnections)
        #expect(model.allowListWarning == nil)
    }

    @Test func editsReachTheFileOnceSettingsAreFlushed() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        model.drafts[.blockedConnections] = "10.0.0.0/8:22"
        model.add(to: .blockedConnections)

        rig.library.flushPendingWrites()

        let stored = try VMConfig.decode(from: Data(contentsOf: rig.library.bundle(rig.id).config))
        #expect(stored.networkPolicy.rules(in: .blockedConnections) == ["10.0.0.0/8:22"])
    }

    @Test func theEditorModelOwnsTheListModelForItsMachine() throws {
        let rig = try makeModel()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let editor = ConfigEditorModel(id: rig.id, library: rig.library)
        editor.network.drafts[.allowedPorts] = "443"
        editor.network.add(to: .allowedPorts)
        #expect(rig.library.machine(rig.id)?.networkPolicy.rules(in: .allowedPorts) == ["443"])
    }

    @Test func modeLabelsAreDistinctAndDescribeTheTrade() {
        #expect(Set(NetworkPolicy.Mode.allCases.map(\.label)).count == NetworkPolicy.Mode.allCases.count)
        #expect(NetworkPolicy.Mode.allowListed.summary.contains("Block rules still win"))
    }
}
