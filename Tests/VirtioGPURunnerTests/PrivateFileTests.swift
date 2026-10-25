import Foundation
import Testing

@testable import VirtioGPURunner

struct PrivateFileTests {
    /// A new directory under /tmp; the test removes it.
    private static func scratch() throws -> String {
        let directory = "/tmp/vmr-private-file-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func mode(of path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    @Test
    func aNewFileHasTheOwnerOnlyModeFromItsCreationWhateverTheUmask() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let previous = umask(0)
        defer { _ = umask(previous) }
        let handle = try PrivateFile.create(atPath: directory + "/new")
        try handle.close()
        #expect(try Self.mode(of: directory + "/new") == 0o600, "the mode was given to open, not set afterwards")
    }

    @Test
    func aNameThatIsTakenIsRefusedAndALinkIsNotFollowed() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try PrivateFile.create(atPath: directory + "/taken").close()
        #expect(throws: (any Error).self) { try PrivateFile.create(atPath: directory + "/taken") }

        try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: directory + "/target")
        #expect(throws: (any Error).self) { try PrivateFile.create(atPath: directory + "/link") }
        #expect(!FileManager.default.fileExists(atPath: directory + "/target"), "nothing was created through the link")
    }

    @Test
    func replaceWritesThePrivateFileWholeAndLeavesNoTemporary() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/scanout.png"
        try PrivateFile.replace(path, with: Data("first".utf8))
        try PrivateFile.replace(path, with: Data("second".utf8))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "second")
        #expect(try Self.mode(of: path) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["scanout.png"])
    }

    @Test
    func replaceRemovesALeftoverTemporaryAndNeverWritesThroughALinkPlantedThere() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let victim = directory + "/victim"
        try Data("keep".utf8).write(to: URL(filePath: victim))
        try FileManager.default.createSymbolicLink(atPath: directory + "/scanout.png.partial", withDestinationPath: victim)
        try PrivateFile.replace(directory + "/scanout.png", with: Data("picture".utf8))
        #expect(try String(contentsOfFile: victim, encoding: .utf8) == "keep")
        #expect(try String(contentsOfFile: directory + "/scanout.png", encoding: .utf8) == "picture")
    }

    @Test
    func replaceInAMissingDirectoryThrows() {
        #expect(throws: (any Error).self) { try PrivateFile.replace("/tmp/vmr-no-such-directory-\(UUID().uuidString)/x", with: Data()) }
    }
}
