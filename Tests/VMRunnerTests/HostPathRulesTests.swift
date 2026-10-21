import Foundation
import Testing

@testable import VMRunner

struct PathContainmentTests {
    private let images = URL(filePath: "/Users/me/Library/Application Support/VMRunner/Images", directoryHint: .isDirectory)

    @Test(arguments: [
        "/Users/me/Library/Application Support/VMRunner/Images/Debian.iso",
        "/Users/me/Library/Application Support/VMRunner/Images/a/b/c.ipsw",
        "/Users/me/Library/Application Support/VMRunner/Images/",
        "/Users/me/Library/Application Support/VMRunner/Images",
        "/Users/me/Library/Application Support/VMRunner/Images/./x/../y.iso",
    ])
    func filesInsideTheDirectoryAreInside(path: String) {
        #expect(AppPaths.isInside(URL(filePath: path), images))
    }

    @Test(arguments: [
        "/Users/me/Library/Application Support/VMRunner/Images2/user.ipsw",
        "/Users/me/Library/Application Support/VMRunner/Images-old/user.ipsw",
        "/Users/me/Library/Application Support/VMRunner/Images/../Images2/user.ipsw",
        "/Users/me/Library/Application Support/VMRunner/user.ipsw",
        "/Users/me/Library/Application Support/VMRunner",
        "/Users/me/Downloads/Images/user.ipsw",
    ])
    func aNeighbourWithTheSamePrefixIsNotInside(path: String) {
        #expect(!AppPaths.isInside(URL(filePath: path), images))
    }

    @Test func linksAreFollowedBeforeComparing() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inside = directory.appending(path: "Images", directoryHint: .isDirectory)
        let outside = directory.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appending(path: "secret.iso"))
        try Data("x".utf8).write(to: inside.appending(path: "x.iso"))
        let outwardLink = inside.appending(path: "looks-cached.iso")
        try FileManager.default.createSymbolicLink(at: outwardLink, withDestinationURL: outside.appending(path: "secret.iso"))
        let inwardLink = outside.appending(path: "dir")
        try FileManager.default.createSymbolicLink(at: inwardLink, withDestinationURL: inside)

        #expect(!AppPaths.isInside(outwardLink, inside), "a cache entry that links out is not the app's to delete")
        #expect(AppPaths.isInside(inwardLink.appending(path: "x.iso"), inside))
    }
}

@MainActor
struct ExtraDiskRulesTests {
    private var ownDisk: String { AppPaths.machines.appending(path: "\(UUID().uuidString).vm/Disk.img").path }

    @Test func aDiskInsideTheMachinesFolderIsRefusedWhenAConfigIsRead() throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.extraDisks = [ExtraDisk(path: ownDisk)]

        let data = try config.encoded()

        #expect(throws: DecodingError.self) { try VMConfig.decode(from: data) }
    }

    @Test func aDiskOutsideTheMachinesFolderIsAccepted() throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.extraDisks = [ExtraDisk(path: "/Users/me/data.img")]
        let sibling = AppPaths.machines.deletingLastPathComponent().appending(path: "Machines2/d.img").path
        config.extraDisks.append(ExtraDisk(path: sibling))

        #expect(try VMConfig.decode(from: config.encoded()).extraDisks.count == 2)
    }

    @Test func thePickerRefusesAnotherMachinesDiskAndSaysWhy() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory.appending(path: "Machines"))
        let config = VMConfig.new(name: "x", guest: .linux)
        try library.add(config)
        let editor = ConfigEditorModel(id: config.id, library: library)
        let otherBundle = library.bundle(UUID())
        try otherBundle.create()
        try Data(count: 512).write(to: otherBundle.disk)
        let other = otherBundle.disk

        editor.importFile(other, for: .extraDisk)

        #expect(editor.alertMessage?.contains(other.path) == true)
        #expect(library.machine(config.id)?.extraDisks.isEmpty == true)
        #expect(library.unapprovedHostPaths(for: config.id).isEmpty)
    }

    @Test func theExposureSummaryShowsTheWholePathOfEveryExtraDisk() throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.extraDisks = [
            ExtraDisk(path: "/Volumes/Backup/vm/data.img", readOnly: true), ExtraDisk(path: "/Volumes/Other/data.img"),
        ]

        let texts = config.exposures.map(\.text)

        #expect(texts.contains("Extra disk (read-only): /Volumes/Backup/vm/data.img"))
        #expect(texts.contains("Extra disk (writable): /Volumes/Other/data.img"), "two disks named data.img must be told apart")
    }
}

struct LoggingTests {
    @Test func theKindOfAnErrorNamesNoPath() {
        let path = "/Users/someone/.ssh/id_ed25519"
        let error = CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])

        #expect(error.logKind == "NSCocoaErrorDomain 260")
        #expect(!error.logKind.contains(path))
        #expect(error.localizedDescription.contains("id_ed25519"), "the description is the part that must be logged privately")
    }

    @Test func theLoggingSubsystemMatchesTheBundleIdentifierInInfoPlist() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Resources/Info.plist"))
        struct InfoPlist: Decodable {
            let identifier: String
            enum CodingKeys: String, CodingKey { case identifier = "CFBundleIdentifier" }
        }
        let plist = try PropertyListDecoder().decode(InfoPlist.self, from: data)

        #expect(plist.identifier == Log.fallbackSubsystem)
    }
}
