import Foundation
import Testing
import Virtualization

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

    @Test func aMachineWithoutAStoredAddressGetsOneThatIsSaved() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let store = RecordingStore(rig.library)
        let guest = rig.factory.add()

        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)

        let booted = try #require(rig.factory.bootedConfigs.first?.macAddress)
        #expect(store.updates.first?.macAddress == booted, "the new address is saved")

        guest.powerOff()
        rig.expectReleased()
    }

    @Test func aMachineWithAnInvalidStoredAddressGetsAValidOneThatIsSaved() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        var config = rig.config
        config.macAddress = "garbage"
        rig.library.update(config)
        let store = RecordingStore(rig.library)
        let guest = rig.factory.add()

        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)

        let booted = try #require(rig.factory.bootedConfigs.first?.macAddress)
        #expect(VZMACAddress(string: booted) != nil, "the new address is a valid one")
        #expect(store.updates.first?.macAddress == booted, "the new address replaces the invalid one in the store")

        guest.powerOff()
        rig.expectReleased()
    }

    @Test func anEphemeralMachineWithoutAFreshIdentityGetsAnAddressThatIsSaved() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        let store = RecordingStore(rig.library)
        let guest = rig.factory.add()

        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)

        let booted = try #require(rig.factory.bootedConfigs.first?.macAddress)
        #expect(store.updates.first?.macAddress == booted, "without a fresh identity the address is kept, so it is saved")

        guest.powerOff()
        rig.expectReleased()
    }

    @Test func aMachineStartedTwiceBootsWithTheSameAddress() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let store = RecordingStore(rig.library)

        let first = rig.factory.add()
        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)
        first.powerOff()
        rig.expectReleased()

        let second = rig.factory.add()
        await rig.controller.start(rig.config, bundle: rig.bundle, library: store)
        let booted = rig.factory.bootedConfigs.map(\.macAddress)

        #expect(booted.count == 2)
        #expect(booted.first.flatMap { $0 } != nil)
        #expect(booted.count == 2 && booted[0] == booted[1], "the second start reuses the saved address")

        second.powerOff()
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
