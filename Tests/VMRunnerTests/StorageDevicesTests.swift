import Foundation
import Testing
import Virtualization

@testable import VMRunner

/// What `ConfigurationBuilder` attaches as storage, decided without starting a machine: building the devices only opens
/// the image files.
struct StorageDevicesTests {
    private func makeBundle(in directory: URL) throws -> VMBundle {
        let bundle = VMBundle(url: directory)
        try Data(count: 1 << 20).write(to: bundle.disk)
        try Data(count: 1 << 20).write(to: bundle.ephemeralDisk)
        return bundle
    }

    private func image(named name: String, in directory: URL) throws -> String {
        let url = directory.appending(path: name)
        try Data(count: 1 << 20).write(to: url)
        return url.path
    }

    @Test func aHardenedLinuxMachineGetsOnlyItsOwnDisk() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "x", guest: .linux)
        config.installerISO = try image(named: "installer.iso", in: directory)
        config.extraDisks = [ExtraDisk(path: try image(named: "extra.img", in: directory))]

        let hardened = config.applying(.hardened)
        let devices = try ConfigurationBuilder.storage(for: hardened, bundle: makeBundle(in: directory))

        #expect(devices.count == 1)
        #expect(devices.allSatisfy { $0 is VZVirtioBlockDeviceConfiguration })
    }

    @Test func anAttachedInstallerIsAReadOnlyUSBDriveAfterTheDisks() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "x", guest: .linux)
        config.installerISO = try image(named: "installer.iso", in: directory)
        config.extraDisks = [ExtraDisk(path: try image(named: "extra.img", in: directory))]
        let bundle = try makeBundle(in: directory)

        let attached = try ConfigurationBuilder.storage(for: config, bundle: bundle)
        #expect(attached.count == 3)
        #expect(attached[0] is VZVirtioBlockDeviceConfiguration && attached[1] is VZVirtioBlockDeviceConfiguration)
        #expect(attached[2] is VZUSBMassStorageDeviceConfiguration)

        config.installerAttached = false
        #expect(try ConfigurationBuilder.storage(for: config, bundle: bundle).count == 2)
    }

    @Test func aMacGuestNeverGetsTheInstallerDrive() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "x", guest: .macOS)
        config.installerISO = try image(named: "installer.iso", in: directory)

        #expect(try ConfigurationBuilder.storage(for: config, bundle: makeBundle(in: directory)).count == 1)
    }
}
