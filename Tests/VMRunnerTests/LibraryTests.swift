import Foundation
import Testing

@testable import VMRunner

@MainActor
struct LibraryTests {
    private func makeLibrary() throws -> (VMLibrary, URL) {
        let directory = try scratchDirectory()
        return (VMLibrary(machinesDirectory: directory), directory)
    }

    private func addMachine(to library: VMLibrary, named name: String = "base") throws -> VMConfig {
        let config = VMConfig.new(name: name, guest: .linux)
        try library.add(config)
        let bundle = library.bundle(config.id)
        try Data("disk".utf8).write(to: bundle.disk)
        try Data("nvram".utf8).write(to: bundle.efiVariables)
        try Data("old-id".utf8).write(to: bundle.machineIdentifier)
        try Data("memory".utf8).write(to: bundle.savedState)
        return config
    }

    @Test func aSettingsChangeReachesTheDiskOnFlushNotBefore() throws {
        let directory = try scratchDirectory()
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        var config = VMConfig.new(name: "before", guest: .linux)
        try library.add(config)
        let file = library.bundle(config.id).config

        config.name = "after"
        library.update(config)
        #expect(try VMConfig.decode(from: Data(contentsOf: file)).name == "before")
        #expect(library.machine(config.id)?.name == "after")

        library.flushPendingWrites()
        #expect(try VMConfig.decode(from: Data(contentsOf: file)).name == "after")
    }

    @Test func duplicateIsAnIndependentMachineWithItsOwnIdentity() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try addMachine(to: library)

        try library.duplicate(original.id)

        #expect(library.machines.count == 2)
        let copy = try #require(library.machines.first { $0.id != original.id })
        #expect(copy.name == "base Copy")
        let copyBundle = library.bundle(copy.id)
        #expect(try String(contentsOf: copyBundle.disk, encoding: .utf8) == "disk")
        #expect(try Data(contentsOf: copyBundle.machineIdentifier) != Data("old-id".utf8), "a clone needs a fresh machine identifier")
        #expect(!copyBundle.hasSavedState, "memory state belongs to the original")
        #expect(library.bundle(original.id).hasSavedState)
        #expect(copy.macAddress == nil)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, "staging folders must not outlive duplicate(): \(leftovers)")
    }

    @Test func aFailedDuplicateLeavesNoMachineBehind() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try addMachine(to: library)
        // Remove the source folder so the clone fails.
        try FileManager.default.removeItem(at: library.bundle(original.id).url)

        #expect(throws: (any Error).self) { try library.duplicate(original.id) }

        #expect(library.machines.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func loadSkipsABundleWhoseFolderDoesNotMatchItsID() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try addMachine(to: library)
        // A stray copy of the folder carries the original's config.json (and so its id).
        let stray = directory.appending(path: "\(UUID().uuidString).vm", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: library.bundle(original.id).url, to: stray)

        let fresh = VMLibrary(machinesDirectory: directory)
        fresh.load()

        #expect(fresh.machines.map(\.id) == [original.id])
    }

    @Test func deletingAMachineRemovesOnlyItsOwnFolder() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try addMachine(to: library, named: "first")
        let second = try addMachine(to: library, named: "second")

        library.delete(first.id)

        #expect(library.machines.map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: library.bundle(first.id).url.path))
        #expect(FileManager.default.fileExists(atPath: library.bundle(second.id).url.path))
    }

    @Test func changingSecureBootDropsSavedState() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = try addMachine(to: library)
        #expect(library.bundle(config.id).hasSavedState)

        config.secureBoot = true
        library.update(config)

        #expect(!library.bundle(config.id).hasSavedState)
    }

    @Test func turningSuspendOffOrDisposableOnDropsSavedState() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try addMachine(to: library)
        let bundle = library.bundle(original.id)

        var noSuspend = original
        noSuspend.allowsSuspend = false
        library.update(noSuspend)
        #expect(!bundle.hasSavedState, "the exposure summary says no memory image is written once suspend is off")

        try Data("memory".utf8).write(to: bundle.savedState)
        var disposable = noSuspend
        disposable.ephemeral = true
        library.update(disposable)
        #expect(!bundle.hasSavedState, "a disposable machine keeps no memory image either")
    }

    @Test func turningSuspendOnOrDisposableOffKeepsSavedState() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = try addMachine(to: library)
        config.ephemeral = true
        config.allowsSuspend = false
        library.update(config)
        let bundle = library.bundle(config.id)
        try Data("memory".utf8).write(to: bundle.savedState)

        config.ephemeral = false
        config.allowsSuspend = true
        library.update(config)

        #expect(bundle.hasSavedState, "loosening a setting writes nothing, and there is nothing to promise")
    }

    @Test func settingsThatDontAffectFirmwareKeepSavedState() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = try addMachine(to: library)

        config.name = "renamed"
        library.update(config)

        #expect(library.bundle(config.id).hasSavedState)
    }

    @Test func machinesAreStoredPrivately() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try addMachine(to: library)

        let attributes = try FileManager.default.attributesOfItem(atPath: library.bundle(config.id).url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test func snapshotsAreRefusedWhileTheMachineIsSuspended() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try addMachine(to: library)

        #expect(throws: SnapshotError.self) { try library.bundle(config.id).takeSnapshot(named: "x", config: config) }
    }
}

@MainActor
struct NewMachineModelTests {
    private func makeModel() throws -> NewMachineModel {
        let suite = "vmrunner-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return NewMachineModel(defaults: defaults)
    }

    @Test func startsReadyToCreateAMacFromTheLatestImage() throws {
        let model = try makeModel()
        #expect(model.canCreate)
        #expect(model.makeConfig().source == .latestMac)
    }

    @Test func aBlankNameCannotBeCreated() throws {
        let model = try makeModel()
        model.config.name = "   "
        #expect(!model.canCreate)
    }

    @Test func localMediaNeedsAFile() throws {
        let model = try makeModel()
        model.macSource = .file
        #expect(!model.canCreate)
        model.localPath = "/tmp/restore.ipsw"
        #expect(model.canCreate)
        #expect(model.makeConfig().source == .local("/tmp/restore.ipsw"))
    }

    @Test func ipswMeNeedsABuildSelected() throws {
        let model = try makeModel()
        model.macSource = .ipswMe
        #expect(!model.canCreate)
        model.selectedBuild = "26A434"
        #expect(model.canCreate)
    }

    @Test func switchingGuestKeepsACustomNameAndResetsDefaults() throws {
        let model = try makeModel()
        model.config.name = "build agent"
        model.localPath = "/tmp/x.iso"
        let id = model.config.id

        model.guestChanged(to: .linux)

        #expect(model.config.name == "build agent")
        #expect(model.config.guest == .linux)
        #expect(model.config.pointingDevice == .mouse)
        #expect(model.config.id == id)
        #expect(model.localPath == nil)
    }

    @Test func switchingGuestRenamesAPlaceholderName() throws {
        let model = try makeModel()
        model.guestChanged(to: .linux)
        #expect(model.config.name == "Linux")
    }

    @Test func linuxDefaultsToTheFirstCatalogImage() throws {
        let model = try makeModel()
        model.guestChanged(to: .linux)
        let first = try #require(LinuxCatalog.images.first)
        #expect(model.makeConfig().source == .linuxCatalog(id: first.id))
    }

    @Test func createAddsTheMachineAndFailsCleanlyOtherwise() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vmrunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        let model = try makeModel()
        model.macSource = .file
        model.localPath = "/nonexistent/restore.ipsw"
        model.config.name = " lab "

        #expect(model.create(in: library))
        library.selectedController?.errorMessage = nil
        #expect(library.machines.map(\.name) == ["lab"])
        library.cancelJob(model.config.id)
    }
}

@MainActor
struct MachineModelTests {
    private func makeLibrary() throws -> (VMLibrary, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vmrunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (VMLibrary(machinesDirectory: directory), directory)
    }

    @Test func aFreshUnprovisionedMachineReportsIncompleteSetup() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = VMConfig.new(name: "m", guest: .linux)
        try library.add(config)

        let model = library.model(for: config.id)

        guard case .setupIncomplete = try #require(model.phase) else {
            Issue.record("expected setupIncomplete")
            return
        }
        #expect(!model.showsControls)
    }

    @Test func aProvisionedStoppedMachineIsEditable() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "m", guest: .linux)
        config.isProvisioned = true
        try library.add(config)

        let model = library.model(for: config.id)

        guard case .editing = try #require(model.phase) else {
            Issue.record("expected editing")
            return
        }
        #expect(model.showsControls && !model.isRunning && !model.isPaused)
    }

    @Test func modelsAreCachedPerMachineAndDroppedOnDelete() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = VMConfig.new(name: "m", guest: .linux)
        try library.add(config)

        let first = library.model(for: config.id)
        #expect(library.model(for: config.id) === first)

        library.delete(config.id)
        #expect(first.phase == nil, "a deleted machine has no phase")
    }

    @Test func startHelpMentionsResumeOnlyWhenThereIsSavedState() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "m", guest: .linux)
        config.isProvisioned = true
        try library.add(config)
        let model = library.model(for: config.id)
        #expect(model.startHelp == "Start the virtual machine")

        try Data("x".utf8).write(to: model.bundle.savedState)

        #expect(model.startHelp == "Resume from suspended state")
    }

    @Test func growingTheDiskRaisesTheFloorAndShrinkingIsClamped() async throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "m", guest: .linux)
        config.isProvisioned = true
        config.diskGiB = 16
        try library.add(config)
        try DiskImage.create(at: library.bundle(config.id).disk, gibibytes: 16)
        let editor = library.model(for: config.id).editor

        editor.setDiskSize(24)
        #expect(library.machine(config.id)?.diskGiB == 24)

        editor.setDiskSize(8)
        #expect(library.machine(config.id)?.diskGiB == max(8, editor.diskFloorGiB), "a shrink request is clamped to the floor")
        #expect((library.machine(config.id)?.diskGiB ?? 0) >= 16)
    }
}
