import Foundation
import Testing

@testable import VMRunner

/// Records every configuration a store is asked to save, and stores it in the library as the library does.
@MainActor
private final class RecordingStore: MachineStore {
    let library: VMLibrary
    private(set) var updates: [VMConfig] = []

    init(_ library: VMLibrary) { self.library = library }

    func bundle(_ id: UUID) -> VMBundle { library.bundle(id) }

    func update(_ config: VMConfig) {
        updates.append(config)
        library.update(config)
    }

    func approveHostPaths(_ grants: [HostPathGrant], for id: UUID) { library.approveHostPaths(grants, for: id) }
}

/// The address a start gives the network card: a disposable machine with a fresh identity boots with a new one for that run
/// only, and a machine without a stored address is given one and keeps it.
@MainActor
struct FreshAddressTests {
    private let storedAddress = "02:00:00:00:00:01"

    @Test func aDisposableRunBootsWithAFreshAddressAndSavesOnlyTheStoredOne() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        var config = rig.config
        config.freshIdentityPerStart = true
        config.macAddress = storedAddress
        rig.library.update(config)
        let store = RecordingStore(rig.library)
        let guest = rig.factory.add()

        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)

        let booted = try #require(rig.factory.bootedConfigs.first?.macAddress)
        #expect(booted != storedAddress, "the run boots with a fresh address")
        #expect(!store.updates.isEmpty)
        #expect(store.updates.allSatisfy { $0.macAddress == storedAddress }, "no save carries the run's address")

        guest.powerOff()
        rig.expectReleased()
    }

    @Test func aMachineWithoutAStoredAddressGetsOneThatIsSavedAndKept() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let store = RecordingStore(rig.library)
        let guest = rig.factory.add()

        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)

        let booted = try #require(rig.factory.bootedConfigs.first?.macAddress)
        #expect(store.updates.first?.macAddress == booted, "the new address is saved")
        #expect(!rig.config.needsNewMACAddress, "the next start reuses the saved address")

        guest.powerOff()
        rig.expectReleased()
    }

    @Test func aMachineWithAStoredAddressKeepsIt() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        var config = rig.config
        config.macAddress = storedAddress
        rig.library.update(config)
        let store = RecordingStore(rig.library)
        let guest = rig.factory.add()

        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)

        #expect(rig.factory.bootedConfigs.first?.macAddress == storedAddress)
        #expect(!store.updates.isEmpty)
        #expect(store.updates.allSatisfy { $0.macAddress == storedAddress }, "the stored address is saved unchanged")

        guest.powerOff()
        rig.expectReleased()
    }
}
