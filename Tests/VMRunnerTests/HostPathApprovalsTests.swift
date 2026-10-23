import Foundation
import Testing

@testable import VMRunner

struct HostPathGrantTests {
    @Test func aWritableApprovalCoversTheReadOnlyOneButNotTheOtherWayAround() {
        let writable = HostPathGrant(.sharedFolder, "/Users/me/work", writable: true)
        let readOnly = HostPathGrant(.sharedFolder, "/Users/me/work", writable: false)

        #expect(writable.covers(readOnly))
        #expect(writable.covers(writable))
        #expect(!readOnly.covers(writable))
    }

    @Test func anApprovalNamesOnePathAndOneKind() {
        let folder = HostPathGrant(.sharedFolder, "/Users/me/work", writable: false)

        #expect(!folder.covers(HostPathGrant(.extraDisk, "/Users/me/work", writable: false)))
        #expect(!folder.covers(HostPathGrant(.sharedFolder, "/Users/me/work2", writable: false)))
    }

    @Test func dotSegmentsDoNotMakeADifferentPath() {
        let direct = HostPathGrant(.installer, "/Users/me/linux.iso", writable: false)
        let indirect = HostPathGrant(.installer, "/Users/me/other/../linux.iso", writable: false)
        #expect(direct == indirect)
    }

    @Test func aConfigListsEveryPathItHandsToTheGuest() {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.sharedFolders = [SharedFolder(path: "/a", readOnly: true), SharedFolder(path: "/b")]
        config.extraDisks = [ExtraDisk(path: "/c.img")]
        config.installerISO = "/d.iso"

        #expect(
            config.hostGrants == [
                HostPathGrant(.sharedFolder, "/a", writable: false), HostPathGrant(.sharedFolder, "/b", writable: true),
                HostPathGrant(.extraDisk, "/c.img", writable: true), HostPathGrant(.installer, "/d.iso", writable: false),
            ])

        config.installerAttached = false
        #expect(!config.hostGrants.contains { $0.kind == .installer }, "a detached installer reaches nothing")
    }
}

@MainActor
struct HostPathApprovalsTests {
    private let secrets = "/Users/someone/.ssh"

    /// A library over a scratch folder with its approvals file beside it, as in the app.
    private func makeLibrary(in directory: URL) -> VMLibrary {
        VMLibrary(machinesDirectory: directory.appending(path: "Machines"), approvalsFile: directory.appending(path: "Approvals.json"))
    }

    /// Puts a machine's bundle on disk the way a copied bundle or an earlier version would, bypassing the library.
    private func plant(_ config: VMConfig, in directory: URL) throws {
        let bundle = VMBundle(id: config.id, in: directory.appending(path: "Machines"))
        try AppPaths.createPrivateDirectory(bundle.url)
        try config.encoded().write(to: bundle.config)
    }

    private func machine(sharing path: String, named name: String = "m") -> VMConfig {
        var config = VMConfig.new(name: name, guest: .linux)
        config.isProvisioned = true
        config.sharedFolders = [SharedFolder(path: path)]
        return config
    }

    @Test func machinesAlreadyOnDiskAreGrandfatheredOnceAndLaterBundlesAreNot() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = machine(sharing: "/Users/me/work", named: "mine")
        try plant(mine, in: directory)

        let upgraded = makeLibrary(in: directory)
        upgraded.load()
        #expect(upgraded.unapprovedHostPaths(for: mine.id).isEmpty, "a machine from before approvals existed keeps working")

        let imported = machine(sharing: secrets, named: "imported")
        try plant(imported, in: directory)
        let later = makeLibrary(in: directory)
        later.load()

        #expect(later.unapprovedHostPaths(for: mine.id).isEmpty)
        #expect(later.unapprovedHostPaths(for: imported.id) == [HostPathGrant(.sharedFolder, secrets, writable: true)])
    }

    @Test func anEmptyLibraryStillRecordsThatApprovalsExist() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        makeLibrary(in: directory).load()

        let imported = machine(sharing: secrets)
        try plant(imported, in: directory)
        let next = makeLibrary(in: directory)
        next.load()

        #expect(!next.unapprovedHostPaths(for: imported.id).isEmpty, "a fresh install does not grandfather a later import")
    }

    @Test func approvalsSurviveARestartAndStayOutsideTheBundle() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        let config = machine(sharing: "/Users/me/work")
        try library.add(config)

        let restarted = makeLibrary(in: directory)
        restarted.load()
        #expect(restarted.unapprovedHostPaths(for: config.id).isEmpty)

        let file = directory.appending(path: "Approvals.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(!FileManager.default.fileExists(atPath: library.bundle(config.id).url.appending(path: "Approvals.json").path))
    }

    @Test func aCopiedBundleKeepsItsPathsButNotTheirApproval() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        let original = machine(sharing: "/Users/me/work")
        try library.add(original)

        // Someone hands over the folder: same settings, new identity, no approval record of ours.
        var copied = original
        copied.id = UUID()
        try plant(copied, in: directory)
        let fresh = makeLibrary(in: directory)
        fresh.load()

        #expect(fresh.unapprovedHostPaths(for: original.id).isEmpty)
        #expect(fresh.unapprovedHostPaths(for: copied.id) == [HostPathGrant(.sharedFolder, "/Users/me/work", writable: true)])
    }

    /// A file in the old flat cache, as a machine made before ADR-0031 names it.
    private func flatCacheInstaller(in directory: URL) throws -> (images: URL, file: URL) {
        let images = directory.appending(path: "Images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let file = images.appending(path: "debian-13.7.0-arm64-netinst.iso")
        try Data("installer".utf8).write(to: file)
        return (images, file)
    }

    private func machine(installer path: String, named name: String) -> VMConfig {
        var config = VMConfig.new(name: name, guest: .linux)
        config.isProvisioned = true
        config.installerISO = path
        return config
    }

    @Test func aMachineFromBeforeTheContentCacheGetsItsOwnCloneOfItsApprovedInstaller() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (images, old) = try flatCacheInstaller(in: directory)
        let config = machine(installer: old.path, named: "old")
        try plant(config, in: directory)

        let library = makeLibrary(in: directory)
        library.load()  // approves the paths of machines from before approvals, as an upgrade does
        library.migrateFlatCacheInstallers(imagesDirectory: images)

        let bundle = library.bundle(config.id)
        #expect(library.machine(config.id)?.installerISO == bundle.installer.path)
        #expect(library.unapprovedHostPaths(for: config.id).isEmpty, "the clone is approved")
        try FileManager.default.removeItem(at: old)
        #expect(try Data(contentsOf: bundle.installer) == Data("installer".utf8), "clearing the images no longer removes it")
    }

    @Test func aCopiedBundleNamingTheOldCacheIsNotGivenAClone() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (images, old) = try flatCacheInstaller(in: directory)
        makeLibrary(in: directory).load()  // from now on approvals are recorded, so a later bundle is not grandfathered
        let imported = machine(installer: old.path, named: "imported")
        try plant(imported, in: directory)

        let library = makeLibrary(in: directory)
        library.load()
        library.migrateFlatCacheInstallers(imagesDirectory: images)

        #expect(library.machine(imported.id)?.installerISO == old.path)
        #expect(!FileManager.default.fileExists(atPath: library.bundle(imported.id).installer.path))
    }

    @Test func onlyAFileDirectlyInTheImagesFolderIsInTheFlatCache() {
        let images = URL(filePath: "/data/Images", directoryHint: .isDirectory)
        #expect(ImageStore.isInFlatCache("/data/Images/a.iso", imagesDirectory: images))
        #expect(!ImageStore.isInFlatCache("/data/Images/\(String(repeating: "a", count: 64))/a.iso", imagesDirectory: images))
        #expect(!ImageStore.isInFlatCache("/data/Images2/a.iso", imagesDirectory: images))
        #expect(!ImageStore.isInFlatCache("/data/Machines/x.vm/Installer.iso", imagesDirectory: images))
    }

    @Test func startingAnUnapprovedMachineAsksInsteadOfStarting() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        makeLibrary(in: directory).load()
        let imported = machine(sharing: secrets)
        try plant(imported, in: directory)
        let library = makeLibrary(in: directory)
        library.load()
        try #require(!library.unapprovedHostPaths(for: imported.id).isEmpty)

        library.startMachine(imported.id)

        let pending = try #require(library.pendingApproval)
        #expect(pending.id == imported.id)
        #expect(pending.message.contains(secrets))
        #expect(!library.controller(for: imported.id).isActive)
    }

    @Test func aLaunchArgumentRefusesWithoutAsking() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        makeLibrary(in: directory).load()
        let imported = machine(sharing: secrets)
        try plant(imported, in: directory)
        let library = makeLibrary(in: directory)
        library.load()

        library.startMachine(imported.id, interactive: false)

        #expect(library.pendingApproval == nil)
        #expect(!library.controller(for: imported.id).isActive)
        #expect(library.controller(for: imported.id).errorMessage == nil)
    }

    @Test func approvingTheListedPathsClearsThem() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        makeLibrary(in: directory).load()
        let imported = machine(sharing: secrets)
        try plant(imported, in: directory)
        let library = makeLibrary(in: directory)
        library.load()

        library.approveHostPaths(library.unapprovedHostPaths(for: imported.id), for: imported.id)

        #expect(library.unapprovedHostPaths(for: imported.id).isEmpty)
    }

    @Test func aSettingsChangeNeverApprovesAPath() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        var config = VMConfig.new(name: "m", guest: .linux)
        try library.add(config)

        config.sharedFolders = [SharedFolder(path: secrets)]
        config.extraDisks = [ExtraDisk(path: "/Users/someone/disk.img")]
        library.update(config)

        #expect(library.unapprovedHostPaths(for: config.id).count == 2)
    }

    @Test func aFolderApprovedReadOnlyAsksAgainWhenItBecomesWritable() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        var config = VMConfig.new(name: "m", guest: .linux)
        try library.add(config)
        library.approveHostPaths([HostPathGrant(.sharedFolder, "/Users/me/work", writable: false)], for: config.id)

        config.sharedFolders = [SharedFolder(path: "/Users/me/work", readOnly: true)]
        library.update(config)
        #expect(library.unapprovedHostPaths(for: config.id).isEmpty)

        config.sharedFolders[0].readOnly = false
        library.update(config)
        #expect(library.unapprovedHostPaths(for: config.id) == [HostPathGrant(.sharedFolder, "/Users/me/work", writable: true)])
    }

    @Test func theEditorsPickersApproveWhatTheUserChose() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        let config = VMConfig.new(name: "m", guest: .linux)
        try library.add(config)
        let editor = ConfigEditorModel(id: config.id, library: library)

        editor.addSharedFolder(URL(filePath: "/Users/me/work"))
        editor.importFile(URL(filePath: "/Users/me/extra.img"), for: .extraDisk)
        editor.importFile(URL(filePath: "/Users/me/rescue.iso"), for: .installerISO)

        let saved = try #require(library.machine(config.id))
        #expect(saved.hostGrants.count == 3)
        #expect(library.unapprovedHostPaths(for: config.id).isEmpty)
    }

    @Test func theSpecPickerStoresThePathAndApprovesItReadOnly() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        let config = VMConfig.new(name: "m", guest: .linux)
        try library.add(config)
        let editor = ConfigEditorModel(id: config.id, library: library)

        editor.importFile(URL(filePath: "/Users/me/machine.yaml"), for: .provisioningSpec)

        let saved = try #require(library.machine(config.id))
        #expect(saved.provisioningSpecPath == "/Users/me/machine.yaml")
        #expect(saved.hostGrants == [HostPathGrant(.provisioningSpec, "/Users/me/machine.yaml", writable: false)])
        #expect(library.unapprovedHostPaths(for: config.id).isEmpty)
    }

    @Test func aDuplicateInheritsOnlyWhatItsSourceHadApproved() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = makeLibrary(in: directory)
        earlier.load()
        let own = machine(sharing: "/Users/me/work", named: "own")
        try earlier.add(own)
        let imported = machine(sharing: secrets, named: "imported")
        try plant(imported, in: directory)
        let library = makeLibrary(in: directory)
        library.load()
        for config in [own, imported] {
            try Data("disk".utf8).write(to: library.bundle(config.id).disk)
            try Data("nvram".utf8).write(to: library.bundle(config.id).efiVariables)
        }

        try library.duplicate(own.id)
        try library.duplicate(imported.id)

        let copyOfOwn = try #require(library.machines.first { $0.name == "own Copy" })
        let copyOfImported = try #require(library.machines.first { $0.name == "imported Copy" })
        #expect(library.unapprovedHostPaths(for: copyOfOwn.id).isEmpty)
        #expect(!library.unapprovedHostPaths(for: copyOfImported.id).isEmpty)
    }

    @Test func deletingAMachineForgetsItsApprovals() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        let config = machine(sharing: "/Users/me/work")
        try library.add(config)

        library.delete(config.id)
        try plant(config, in: directory)
        let fresh = makeLibrary(in: directory)
        fresh.load()

        #expect(!fresh.unapprovedHostPaths(for: config.id).isEmpty)
    }

    @Test func anUnreadableApprovalsFileApprovesNothing() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appending(path: "Approvals.json"))
        let config = machine(sharing: "/Users/me/work")
        try plant(config, in: directory)

        let library = makeLibrary(in: directory)
        library.load()

        #expect(!library.unapprovedHostPaths(for: config.id).isEmpty, "a damaged file must not grandfather anything")
    }
}
