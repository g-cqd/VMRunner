import Foundation
import Testing
import Virtualization

@testable import VMRunner

/// A fresh identity per disposable start: what decides it, where the identifier lives, and that it goes with the
/// disposable copy.
struct GuestIdentityTests {
    @Test func onlyADisposableMachineWithTheSwitchOnGetsAFreshIdentity() throws {
        var config = VMConfig.new(name: "i", guest: .linux)
        config.macAddress = "02:00:00:00:00:01"
        config.freshIdentityPerStart = true
        #expect(!config.needsNewMACAddress && config.makeFreshMachineIdentity() == nil, "not disposable")
        config.ephemeral = true
        #expect(config.needsNewMACAddress)
        let linux = try #require(config.makeFreshMachineIdentity())
        #expect(VZGenericMachineIdentifier(dataRepresentation: linux) != nil)
        var mac = VMConfig.new(name: "m", guest: .macOS)
        mac.ephemeral = true
        mac.freshIdentityPerStart = true
        #expect(VZMacMachineIdentifier(dataRepresentation: try #require(mac.makeFreshMachineIdentity())) != nil)
        config.freshIdentityPerStart = false
        #expect(!config.needsNewMACAddress && config.makeFreshMachineIdentity() == nil, "the switch is off")
    }

    @Test func aConfigWrittenBeforeTheSwitchKeepsItsIdentityAtEachStart() throws {
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        #expect(!(try VMConfig.decode(from: Data(old.utf8))).freshIdentityPerStart)
    }

    @Test func theDisposableCopyKeepsItsOwnIdentifierAndDiscardsIt() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data("disk".utf8).write(to: bundle.disk)
        try Data("nvram".utf8).write(to: bundle.efiVariables)
        try Data("own".utf8).write(to: bundle.machineIdentifier)

        try bundle.prepareEphemeral(guest: .linux)
        #expect(bundle.activeMachineIdentifier(ephemeral: true) == bundle.machineIdentifier, "no identity given")
        try bundle.prepareEphemeral(guest: .linux, identity: Data("fresh".utf8))
        #expect(bundle.activeMachineIdentifier(ephemeral: true) == bundle.ephemeralMachineIdentifier)
        #expect(bundle.activeMachineIdentifier(ephemeral: false) == bundle.machineIdentifier)
        #expect(try String(contentsOf: bundle.machineIdentifier, encoding: .utf8) == "own", "the machine's own is untouched")
        bundle.discardEphemeral()
        #expect(!FileManager.default.fileExists(atPath: bundle.ephemeralMachineIdentifier.path))
    }
}

/// The controller: each disposable start with the switch on stores a new address, and the identifier goes with the run.
@MainActor
struct GuestIdentityStartTests {
    @Test func eachDisposableStartGetsANewAddressAndItsOwnIdentifier() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        var config = rig.config
        config.freshIdentityPerStart = true
        config.macAddress = "02:00:00:00:00:01"
        rig.library.update(config)

        let first = rig.factory.add()
        await rig.start()
        let firstAddress = rig.factory.bootedConfigs.last?.macAddress
        #expect(firstAddress != nil && firstAddress != "02:00:00:00:00:01")
        #expect(rig.config.macAddress == "02:00:00:00:00:01", "the run's address is not saved into the machine")
        #expect(FileManager.default.fileExists(atPath: rig.bundle.ephemeralMachineIdentifier.path))
        first.powerOff()
        rig.expectReleased()
        #expect(!FileManager.default.fileExists(atPath: rig.bundle.ephemeralMachineIdentifier.path))

        let second = rig.factory.add()
        await rig.start()
        #expect(rig.factory.bootedConfigs.last?.macAddress != firstAddress)
        second.powerOff()
        rig.expectReleased()
    }
}

/// The identity settings' labels and help: honest about what a guest can still tell, and naming the prefixes it uses.
struct GuestIdentityHelpTests {
    @Test func theHelpSaysWhatAGuestCanStillTell() {
        let entry = HelpTopic.guestIdentity.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for phrase in ["hypervisor", "virtio devices", "timing", "cannot change", "not for getting around"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
        for prefix in MACVendor.allCases.compactMap(\.prefix) {
            #expect(text.contains(prefix.map { [$0].hexString }.joined(separator: ":").uppercased()))
        }
        #expect(HelpTopic.macAddress.entry.related.contains(.guestIdentity))
    }

    @Test func everyChoiceHasALabel() {
        #expect(MACVendor.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(DiskInterface.allCases.map(\.label) == ["Virtio", "NVMe"])
    }
}
