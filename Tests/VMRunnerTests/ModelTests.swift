import Foundation
import Testing

@testable import VMRunner

struct ConfigTests {
    @Test func roundTripsAndDropsProvisioningPassword() throws {
        var config = VMConfig.new(name: "ci", guest: .linux)
        config.sharedFolders = [SharedFolder(path: "/tmp/work", readOnly: true)]
        config.source = .remote(URL(string: "https://example.com/a.iso")!, checksum: Checksum(algorithm: .sha256, value: "ab"))
        config.provisioning.password = "hunter2"

        let decoded = try VMConfig.decode(from: config.encoded())

        #expect(decoded.name == "ci")
        #expect(decoded.sharedFolders == config.sharedFolders)
        #expect(decoded.source == config.source)
        #expect(decoded.provisioning.password.isEmpty)
        #expect(!(String(bytes: try config.encoded(), encoding: .utf8) ?? "").contains("hunter2"))
    }

    @Test func decodesConfigsWrittenBeforeNewKeysExisted() throws {
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"#
            + #""diskGiB":32,"audioInput":true,"provisioning":{"username":"me"}}"#

        let config = try VMConfig.decode(from: Data(old.utf8))

        #expect(config.name == "legacy")
        #expect(config.cpuCount == 2)
        #expect(config.audioInput)
        #expect(config.provisioning.username == "me")
        #expect(config.provisioning.fullName == "Admin")
        #expect(config.fitsWindowAtStart)
        #expect(config.pointingDevice == .mouse)
    }

    @Test func linuxDefaultsToMouseAndMacToTrackpad() {
        #expect(VMConfig.new(name: "l", guest: .linux).pointingDevice == .mouse)
        #expect(VMConfig.new(name: "m", guest: .macOS).pointingDevice == .trackpad)
    }

    @Test func sharedFolderUsesLastPathComponentAsName() {
        #expect(SharedFolder(path: "/Users/me/Projects/app").name == "app")
    }
}

struct SecurityTests {
    @Test func newMachinesStartAsStandard() {
        #expect(VMConfig.new(name: "a", guest: .linux).detectedProfile == .standard)
        #expect(VMConfig.new(name: "a", guest: .macOS).detectedProfile == .standard)
    }

    @Test(arguments: SecurityProfile.allCases, GuestOS.allCases)
    func everyProfileIsDetectedAfterApplying(profile: SecurityProfile, guest: GuestOS) {
        let config = VMConfig.new(name: "x", guest: guest).applying(profile)
        #expect(config.detectedProfile == profile)
    }

    @Test func editingASettingMakesTheProfileCustom() {
        var config = VMConfig.new(name: "x", guest: .linux).applying(.isolated)
        config.networkMode = .nat
        #expect(config.detectedProfile == nil)
    }

    @Test func hardenedClosesEveryHostChannel() {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.sharedFolders = [SharedFolder(path: "/tmp/a")]
        config.extraDisks = [ExtraDisk(path: "/tmp/d.img")]
        config.rosetta = true

        let hardened = config.applying(.hardened)

        #expect(hardened.networkMode == .none)
        #expect(hardened.sharedFolders.isEmpty && hardened.extraDisks.isEmpty)
        #expect(!hardened.sharesClipboard && !hardened.rosetta && !hardened.audioInput && !hardened.audioOutput)
        #expect(hardened.ephemeral && !hardened.allowsSuspend)
        #expect(hardened.secureBoot == HostCapabilities.secureBoot, "only enabled where the host can enforce it")
        #expect(hardened.maxRuntimeMinutes > 0)
        #expect(hardened.entropyDevice, "entropy must stay on or the guest has no randomness")
    }

    @Test func containedKeepsFoldersButMakesThemReadOnly() {
        var config = VMConfig.new(name: "x", guest: .macOS)
        config.sharedFolders = [SharedFolder(path: "/tmp/a", readOnly: false)]
        #expect(config.applying(.contained).sharedFolders.map(\.readOnly) == [true])
    }

    @Test func exposureSummaryFlagsWritableSharesAsHighestRisk() {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.sharedFolders = [SharedFolder(path: "/Users/me", readOnly: false)]
        #expect(config.exposures.map(\.level).max() == .high)
        #expect(config.applying(.isolated).exposures.map(\.level).max() != .high)
    }
}

struct APFSTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vmrunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func freeBytes(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0)
    }

    @Test func cloneSharesBlocksAndDiverges() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "a.img")
        try Data(repeating: 0xAB, count: 256 << 20).write(to: source)
        try #require(APFS.supportsCloning(at: dir), "test volume must be APFS")

        let before = try freeBytes(dir)
        let copy = dir.appending(path: "b.img")
        try APFS.clone(source, to: copy)
        let used = before - (try freeBytes(dir))

        #expect(used < 16 << 20, "cloning 256 MB used \(used) bytes")

        let handle = try FileHandle(forWritingTo: copy)
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        #expect(try Data(contentsOf: source).first == 0xAB)
        #expect(try Data(contentsOf: copy).first == 0x00)
    }

    @Test func snapshotRestoresEarlierDiskAndFirmwareState() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        let config = VMConfig.new(name: "s", guest: .linux)
        try Data("v1".utf8).write(to: bundle.disk)
        try Data("nvram1".utf8).write(to: bundle.efiVariables)

        let snapshot = try bundle.takeSnapshot(named: "before", config: config)
        try Data("v2".utf8).write(to: bundle.disk)
        try Data("nvram2".utf8).write(to: bundle.efiVariables)
        try Data("memory".utf8).write(to: bundle.savedState)
        #expect(bundle.listSnapshots().map(\.name) == ["before"])

        try bundle.restoreSnapshot(snapshot, guest: .linux)

        #expect(try String(contentsOf: bundle.disk, encoding: .utf8) == "v1")
        #expect(try String(contentsOf: bundle.efiVariables, encoding: .utf8) == "nvram1")
        #expect(!bundle.hasSavedState, "a memory snapshot is invalid once the disk changes")

        bundle.deleteSnapshot(snapshot)
        #expect(bundle.listSnapshots().isEmpty)
    }

    @Test func ephemeralCopiesLeaveTheOriginalUntouched() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        try Data("disk".utf8).write(to: bundle.disk)
        try Data("aux".utf8).write(to: bundle.auxiliaryStorage)

        try bundle.prepareEphemeral(guest: .macOS)
        try Data("malware".utf8).write(to: bundle.ephemeralDisk)
        #expect(try String(contentsOf: bundle.disk, encoding: .utf8) == "disk")
        #expect(FileManager.default.fileExists(atPath: bundle.ephemeralAuxiliaryStorage.path))

        bundle.discardEphemeral()
        #expect(!FileManager.default.fileExists(atPath: bundle.ephemeralDisk.path))
        #expect(!FileManager.default.fileExists(atPath: bundle.ephemeralAuxiliaryStorage.path))
    }

    @Test func directoryCloneDuplicatesAWholeBundle() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "a.vm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: source.appending(path: "Disk.img"))

        let copy = dir.appending(path: "b.vm", directoryHint: .isDirectory)
        try APFS.clone(source, to: copy)

        #expect(try String(contentsOf: copy.appending(path: "Disk.img"), encoding: .utf8) == "disk")
    }
}

struct DisplayChoiceTests {
    @Test func newConfigsMatchTheWindow() {
        #expect(VMConfig.new(name: "a", guest: .linux).displayChoice == .matchWindow)
    }

    @Test func choosingAPresetSetsAFixedSize() throws {
        var config = VMConfig.new(name: "a", guest: .linux)
        let preset = try #require(DisplayPreset.all.last)

        config.displayChoice = .preset(preset)

        #expect(!config.fitsWindowAtStart)
        #expect(config.displayWidth == preset.width && config.displayHeight == preset.height)
        #expect(config.displayChoice == .preset(preset))
    }

    @Test func customStaysCustomEvenWhenTheSizeMatchesAPreset() throws {
        var config = VMConfig.new(name: "a", guest: .linux)
        let preset = try #require(DisplayPreset.all.first)
        config.displayChoice = .preset(preset)

        config.displayChoice = .custom

        #expect(config.displayChoice == .custom, "picking Custom must not snap back to the matching preset")
        #expect(config.displayWidth == preset.width, "switching to Custom keeps the current size as a starting point")
    }

    @Test func anOddSizeWithoutTheFlagIsCustom() {
        var config = VMConfig.new(name: "a", guest: .linux)
        config.fitsWindowAtStart = false
        config.displayWidth = 1111
        #expect(config.displayChoice == .custom)
    }

    @Test func switchingBackToMatchWindowClearsCustom() {
        var config = VMConfig.new(name: "a", guest: .linux)
        config.displayChoice = .custom
        config.displayChoice = .matchWindow
        #expect(config.fitsWindowAtStart && !config.usesCustomDisplaySize)
    }
}

struct DiskImageTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func diskImageIsSparseAndOnlyGrows() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        try DiskImage.create(at: file, gibibytes: 2)
        try DiskImage.grow(at: file, toGibibytes: 4)
        try DiskImage.grow(at: file, toGibibytes: 1)

        let values = try file.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        #expect(values.fileSize == 4 << 30)
        #expect((values.totalFileAllocatedSize ?? .max) < 1 << 20)
    }
}
