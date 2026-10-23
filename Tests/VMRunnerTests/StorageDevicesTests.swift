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

    @Test func aSpecInUseAttachesItsSeedAsAReadOnlyUSBDriveAfterTheDisks() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "x", guest: .linux)
        config.extraDisks = [ExtraDisk(path: try image(named: "extra.img", in: directory))]
        config.provisioningSpecPath = "/Users/me/machine.yaml"
        let bundle = try makeBundle(in: directory)
        try Data(count: 1 << 20).write(to: bundle.provisioningSeed)

        let attached = try ConfigurationBuilder.storage(for: config, bundle: bundle)
        #expect(attached.count == 3)
        #expect(attached[0] is VZVirtioBlockDeviceConfiguration && attached[1] is VZVirtioBlockDeviceConfiguration)
        let drive = try #require(attached[2] as? VZUSBMassStorageDeviceConfiguration)
        let seed = try #require(drive.attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(seed.isReadOnly)
        #expect(seed.url.lastPathComponent == "ProvisioningSeed.iso")
    }

    @Test func aSpecInUseWithoutItsSeedFailsTheBuildInsteadOfStartingWithoutIt() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "x", guest: .linux)
        config.provisioningSpecPath = "/Users/me/machine.yaml"

        #expect(throws: SetupError.self) { try ConfigurationBuilder.storage(for: config, bundle: makeBundle(in: directory)) }
    }

    @Test func noSeedForAMacGuestOrWhileTheInstallerIsAttached() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory)
        try Data(count: 1 << 20).write(to: bundle.provisioningSeed)
        var mac = VMConfig.new(name: "m", guest: .macOS)
        mac.provisioningSpecPath = "/Users/me/machine.yaml"
        #expect(try ConfigurationBuilder.storage(for: mac, bundle: bundle).count == 1)

        var installing = VMConfig.new(name: "x", guest: .linux)
        installing.provisioningSpecPath = "/Users/me/machine.yaml"
        installing.installerISO = try image(named: "installer.iso", in: directory)
        let attached = try ConfigurationBuilder.storage(for: installing, bundle: bundle)
        #expect(attached.count == 2)
        let drive = try #require(attached[1] as? VZUSBMassStorageDeviceConfiguration)
        let installer = try #require(drive.attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(installer.url.lastPathComponent == "installer.iso", "the installer, not the seed")
    }

    @Test func aDiskFromTheMachinesFolderIsNeverAttached() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "x", guest: .linux)
        let other = AppPaths.machines.appending(path: "\(UUID().uuidString).vm/Disk.img").path
        config.extraDisks = [ExtraDisk(path: other)]

        #expect(throws: HostPathError.self) { try ConfigurationBuilder.storage(for: config, bundle: makeBundle(in: directory)) }
    }

    @Test func aMacGuestNeverGetsTheInstallerDrive() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "x", guest: .macOS)
        config.installerISO = try image(named: "installer.iso", in: directory)

        #expect(try ConfigurationBuilder.storage(for: config, bundle: makeBundle(in: directory)).count == 1)
    }

    @Test func aLinuxMachineCanHaveItsDiskOnNVMeAndAMacCannot() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var linux = VMConfig.new(name: "x", guest: .linux)
        linux.diskInterface = .nvme
        let linuxDisks = try ConfigurationBuilder.storage(for: linux, bundle: makeBundle(in: directory))
        #expect(linuxDisks[0] is VZNVMExpressControllerDeviceConfiguration)
        var mac = VMConfig.new(name: "m", guest: .macOS)
        mac.diskInterface = .nvme
        #expect(try ConfigurationBuilder.storage(for: mac, bundle: makeBundle(in: directory))[0] is VZVirtioBlockDeviceConfiguration)
    }

    @Test func aVirtioDiskReportsTheSerialNumber() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory)
        var config = VMConfig.new(name: "x", guest: .linux)
        let plain = try #require(try ConfigurationBuilder.storage(for: config, bundle: bundle)[0] as? VZVirtioBlockDeviceConfiguration)
        #expect(plain.blockDeviceIdentifier.isEmpty)
        config.diskSerial = "VMR0000000001"
        let disk = try #require(try ConfigurationBuilder.storage(for: config, bundle: bundle)[0] as? VZVirtioBlockDeviceConfiguration)
        #expect(disk.blockDeviceIdentifier == "VMR0000000001")
    }

    @Test func aSerialNumberThatIsNotASCIIIsRefusedWhereTheConfigIsRead() throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.diskSerial = "é"
        #expect(throws: DecodingError.self) { try VMConfig.decode(from: config.encoded()) }
    }

    @Test func theEditorKeepsOnlyPrintableASCIIWithoutSpacesInASerialNumber() {
        #expect(IdentitySection.serialNumber(typed: "VMR 0001\t\u{7}é\n~!") == "VMR0001~!")
        #expect(IdentitySection.serialNumber(typed: String(repeating: "9", count: 30)).count == EditorLimits.maxDiskSerialLength)
    }

    @Test func aConfigWrittenBeforeTheDiskSettingsKeepsTheDefaults() throws {
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        let config = try VMConfig.decode(from: Data(old.utf8))
        #expect(config.diskInterface == .virtio && config.diskSerial.isEmpty)
    }

    @Test func aSerialEditOnAnNVMeDiskKeepsTheSavedState() {
        var previous = VMConfig.new(name: "x", guest: .linux)
        previous.diskInterface = .nvme
        var edited = previous
        edited.diskSerial = "VMR0000000002"
        #expect(edited.restoresSavedState(of: previous), "an NVMe drive takes no serial number")
    }

    @Test func anInterfaceChangeOnAMacKeepsTheSavedState() {
        let previous = VMConfig.new(name: "m", guest: .macOS)
        var edited = previous
        edited.diskInterface = .nvme
        #expect(edited.restoresSavedState(of: previous), "a macOS guest always gets a virtio disk")
    }

    @Test func aSerialEditOnAVirtioDiskDiscardsTheSavedState() {
        let previous = VMConfig.new(name: "x", guest: .linux)
        var edited = previous
        edited.diskSerial = "VMR0000000002"
        #expect(!edited.restoresSavedState(of: previous))
    }

    @Test func aSpecAddedRemovedOrMovedDiscardsTheSavedState() {
        let previous = VMConfig.new(name: "x", guest: .linux)
        var edited = previous
        edited.provisioningSpecPath = "/Users/me/machine.yaml"
        #expect(!edited.restoresSavedState(of: previous), "a seed drive added")
        #expect(!previous.restoresSavedState(of: edited), "a seed drive removed")
        var moved = edited
        moved.provisioningSpecPath = "/Users/me/other.yaml"
        #expect(!moved.restoresSavedState(of: edited), "another spec, another seed")
        #expect(edited.restoresSavedState(of: edited))
    }

    @Test func aSpecThatIsNotInUseKeepsTheSavedState() {
        let mac = VMConfig.new(name: "m", guest: .macOS)
        var macEdited = mac
        macEdited.provisioningSpecPath = "/Users/me/machine.yaml"
        #expect(macEdited.restoresSavedState(of: mac), "a macOS guest gets no seed")
        var installing = VMConfig.new(name: "x", guest: .linux)
        installing.installerISO = "/Users/me/installer.iso"
        var installingEdited = installing
        installingEdited.provisioningSpecPath = "/Users/me/machine.yaml"
        #expect(installingEdited.restoresSavedState(of: installing), "no seed while the installer is attached")
    }
}
