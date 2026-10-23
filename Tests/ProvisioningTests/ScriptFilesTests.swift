import Foundation
import Testing

@testable import Provisioning

/// The script `scripts/hello.sh` of the spec below, and its SHA-256 (computed outside this code, with a separate tool).
private let hello = "#!/bin/sh\necho hello\n"
private let helloDigest = "bfdeaeb08cffb6a36438bcd12dda25417e3cdd36f1e7e482a2849d539225288b"

private func spec(file: String = "scripts/hello.sh", sha256: String = helloDigest) throws -> ProvisioningSpec {
    try ProvisioningSpec(
        parsing: """
            apiVersion: vmrunner.dev/v1alpha1
            kind: Provisioning
            metadata:
              name: node
            spec:
              provision:
              - at: first-boot
                file: \(file)
                sha256: \(sha256)
            """)
}

struct ScriptFilesTests {
    private func write(_ text: String, to path: String, in folder: URL) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func refusal(in folder: URL, limits: ProvisioningLimits = .standard) throws -> ProvisioningError {
        let checked = try spec()
        return try #require(throws: ProvisioningError.self) { try ScriptFiles.verify(checked, in: folder, limits: limits) }
    }

    @Test
    func aMatchingFileIsReturnedWithTheBytesThatWereHashed() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(hello, to: "scripts/hello.sh", in: folder)
        let scripts = try ScriptFiles.verify(try spec(), in: folder)
        #expect(scripts.contents(of: "scripts/hello.sh") == Array(hello.utf8))
        #expect(scripts.contents(of: "scripts/other.sh") == nil)
    }

    @Test
    func aFileThatDoesNotMatchItsDigestRefusesTheSpecWithTheStepsLine() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("#!/bin/sh\necho hello!\n", to: "scripts/hello.sh", in: folder)
        let error = try refusal(in: folder)
        #expect(error.line == 7)
        #expect(error.message.contains("does not match its sha256"), "\(error)")
        #expect(error.message.contains(helloDigest), "\(error)")
    }

    @Test
    func aMissingFileOrAFolderIsRefused() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try refusal(in: folder).message == "scripts/hello.sh is not a regular file")
        try FileManager.default.createDirectory(at: folder.appending(path: "scripts/hello.sh"), withIntermediateDirectories: true)
        #expect(try refusal(in: folder).message == "scripts/hello.sh is not a regular file")
    }

    @Test
    func aSymbolicLinkIsRefusedEvenToAMatchingFile() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(hello, to: "scripts/real.sh", in: folder)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "scripts/hello.sh"), withDestinationURL: folder.appending(path: "scripts/real.sh"))
        let error = try refusal(in: folder)
        #expect(error.line == 7)
        #expect(error.message.contains("symbolic link"), "\(error)")
    }

    @Test
    func aFolderOnTheWayThatIsALinkIsRefused() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(hello, to: "elsewhere/hello.sh", in: folder)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "scripts"), withDestinationURL: folder.appending(path: "elsewhere"))
        #expect(try refusal(in: folder).message == "scripts/hello.sh goes through a symbolic link")
    }

    @Test
    func aSpecWithoutFilesReadsNothing() throws {
        let inline = try ProvisioningSpec(
            parsing: """
                apiVersion: vmrunner.dev/v1alpha1
                kind: Provisioning
                metadata:
                  name: node
                spec:
                  provision:
                  - at: first-boot
                    script: |
                      #!/bin/sh
                      true
                """)
        let scripts = try ScriptFiles.verify(inline, in: URL(filePath: "/nonexistent-\(UUID().uuidString)"))
        #expect(scripts.contents(of: "scripts/hello.sh") == nil)
    }

    // MARK: Limits

    @Test
    func aFileAtTheSizeLimitIsReadAndOneByteMoreIsRefused() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(hello, to: "scripts/hello.sh", in: folder)
        var limits = ProvisioningLimits.standard
        limits.maxFileBytes = hello.utf8.count
        #expect(try ScriptFiles.verify(try spec(), in: folder, limits: limits).contents(of: "scripts/hello.sh")?.count == 21)
        limits.maxFileBytes = hello.utf8.count - 1
        #expect(try refusal(in: folder, limits: limits).message == "scripts/hello.sh is larger than 20 bytes")
    }
}
