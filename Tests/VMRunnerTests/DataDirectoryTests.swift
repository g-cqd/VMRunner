import Foundation
import Testing

@testable import VMRunner

/// `VMRUNNER_DATA_DIR` moves everything the app stores, and a value that cannot be used is refused, never replaced by the
/// default (which would put a test run on the user's own library).
struct DataDirectoryTests {
    private func resolve(_ value: String?) throws -> URL {
        try AppPaths.resolveRoot(environment: value.map { [AppPaths.dataDirectoryVariable: $0] } ?? [:])
    }

    @Test func withoutTheVariableTheDefaultFolderIsUsed() throws {
        #expect(try resolve(nil) == AppPaths.defaultRoot)
        #expect(try resolve("") == AppPaths.defaultRoot)
    }

    @Test func aFolderThatDoesNotExistYetIsAccepted() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let wanted = scratch.appending(path: "library", directoryHint: .isDirectory)

        #expect(try resolve(wanted.path) == wanted)
    }

    @Test func anExistingPrivateFolderIsAccepted() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)

        #expect(try resolve(scratch.path) == scratch)
    }

    @Test func aRelativeOrDotDotPathIsRefused() {
        for value in ["library", "~/library", "./library", "/tmp/a/../b", "/"] {
            #expect(throws: AppPaths.UnsafeDirectory.self, "\(value)") { try resolve(value) }
        }
    }

    @Test func aLinkIsRefusedRatherThanFollowed() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = scratch.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: AppPaths.UnsafeDirectory.self) { try resolve(link.path) }
    }

    @Test func aFileOrAFolderOthersCanWriteToIsRefused() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "file")
        try Data("x".utf8).write(to: file)
        let open = scratch.appending(path: "open", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: open.path)

        #expect(throws: AppPaths.UnsafeDirectory.self) { try resolve(file.path) }
        #expect(throws: AppPaths.UnsafeDirectory.self) { try resolve(open.path) }
    }

    @Test func aRefusedOverrideNeverPointsAtTheDefaultFolder() {
        #expect(!AppPaths.isInside(AppPaths.refusedRoot, AppPaths.defaultRoot))
        #expect(throws: (any Error).self) { try AppPaths.createPrivateDirectory(AppPaths.refusedRoot.appending(path: "Machines")) }
    }
}
