import Foundation
import Testing

@testable import VMRunner

/// A machine bundle is a folder anyone can copy or hand over, so what it says about itself is checked against where it is,
/// and what the app writes into it is private to the user.
struct BundleHardeningTests {
    private func mode(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func makeBundle(in directory: URL) throws -> VMBundle {
        let bundle = VMBundle(url: directory)
        try Data("disk".utf8).write(to: bundle.disk)
        try writeEFIVariableStore(at: bundle.efiVariables)
        return bundle
    }

    @Test func aCopiedSnapshotFolderIsNotASecondSnapshot() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory)
        let snapshot = try bundle.takeSnapshot(named: "before", config: VMConfig.new(name: "x", guest: .linux))

        // The copy carries snapshot.json, and so the original's id, under a folder name that isn't that id.
        let original = bundle.snapshots.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: original, to: bundle.snapshots.appending(path: UUID().uuidString, directoryHint: .isDirectory))

        #expect(bundle.listSnapshots().map(\.id) == [snapshot.id])
    }

    @Test func snapshotsArePrivateToTheUser() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory)
        let snapshot = try bundle.takeSnapshot(named: "before", config: VMConfig.new(name: "x", guest: .linux))
        let folder = bundle.snapshots.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory)

        #expect(try mode(of: bundle.snapshots) == 0o700)
        #expect(try mode(of: folder) == 0o700)
        #expect(try mode(of: folder.appending(path: "snapshot.json")) == 0o600)
    }

    @Test func aSavedStateFileIsRestrictedToTheUser() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data("guest memory".utf8).write(to: bundle.savedState)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundle.savedState.path)

        try bundle.restrictSavedState()

        #expect(try mode(of: bundle.savedState) == 0o600)
    }

    @Test func privatelyWrittenFilesAreReadableByTheUserOnly() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try Data("{\"a\":1}".utf8).writePrivately(to: file)

        #expect(try mode(of: file) == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"a\":1}")
    }

    @Test func cloningRefusesASymbolicLinkSource() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appending(path: "secret")
        try Data("key".utf8).write(to: secret)
        let link = directory.appending(path: "Disk.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let folder = directory.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderLink = directory.appending(path: "bundle.vm")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)

        for source in [link, folderLink] {
            let copy = directory.appending(path: "copy-\(source.lastPathComponent)")
            #expect(throws: APFS.CloneError.self) { try APFS.clone(source, to: copy) }
            #expect(!FileManager.default.fileExists(atPath: copy.path), "nothing is cloned from a link")
        }
        #expect(throws: APFS.CloneError.self) { try APFS.clone(link, to: directory.appending(path: "again")) }
    }

    @Test func cloningARegularFileStillWorks() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "a")
        try Data("data".utf8).write(to: source)

        try APFS.clone(source, to: directory.appending(path: "b"))

        #expect(try String(contentsOf: directory.appending(path: "b"), encoding: .utf8) == "data")
    }
}

@MainActor
struct LibraryHardeningTests {
    private func makeLibrary() throws -> (VMLibrary, URL) {
        let directory = try scratchDirectory()
        return (VMLibrary(machinesDirectory: directory), directory)
    }

    @Test func loadIgnoresABundleThatIsASymbolicLink() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = VMConfig.new(name: "real", guest: .linux)
        try library.add(real)

        // A bundle kept elsewhere and linked in under a well-formed name would let its owner swap it after the app looked.
        let elsewhere = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let linked = VMConfig.new(name: "linked", guest: .linux)
        let target = elsewhere.appending(path: "\(linked.id.uuidString).vm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try linked.encoded().write(to: target.appending(path: "config.json"))
        try FileManager.default.createSymbolicLink(at: library.bundle(linked.id).url, withDestinationURL: target)

        let fresh = VMLibrary(machinesDirectory: directory)
        fresh.load()

        #expect(fresh.machines.map(\.name) == ["real"])
    }

    @Test func configFilesAreWrittenPrivately() throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = VMConfig.new(name: "a", guest: .linux)
        try library.add(config)
        let file = library.bundle(config.id).config
        func mode() throws -> Int? { try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int }
        #expect(try mode() == 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        config.name = "b"
        library.update(config)
        library.flushPendingWrites()
        #expect(try mode() == 0o600, "the debounced save writes it privately too")

        try Data("disk".utf8).write(to: library.bundle(config.id).disk)
        try writeEFIVariableStore(at: library.bundle(config.id).efiVariables)
        try library.duplicate(config.id)
        let copy = try #require(library.machines.first { $0.id != config.id })
        let copyMode = try FileManager.default.attributesOfItem(atPath: library.bundle(copy.id).config.path)[.posixPermissions] as? Int
        #expect(copyMode == 0o600)
    }
}
