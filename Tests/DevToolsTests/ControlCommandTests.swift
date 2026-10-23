import Foundation
import GuestConsole
import Testing

@testable import DevTools

/// The real `vmr control` binary. Every run names a socket in a short private folder under `/tmp` or sets
/// `VMRUNNER_DATA_DIR` to one, so no run looks at the user's own data folder.
struct ControlCommandTests {
    /// A short private folder: a local socket path holds about 100 bytes, and the usual temporary path is too long.
    private func withShortFolder<Value>(_ body: (URL) async throws -> Value) async throws -> Value {
        let folder = URL(filePath: "/tmp/vmr-cc-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await body(folder)
    }

    @Test
    func statusWithoutASocketSaysTheServiceIsOffAndExits69() async throws {
        try await withShortFolder { folder in
            let run = try await VMR.vmr(["control", "status"], in: folder, environment: ["VMRUNNER_DATA_DIR": folder.path])
            #expect(run.status == 69, "\(run.combined)")
            #expect(run.error.contains("no socket at \(folder.path)/Control/control.sock"), "\(run.error)")
            #expect(run.output.isEmpty)
        }
    }

    @Test
    func statusWithASocketNobodyServesSaysNothingAnswers() async throws {
        try await withShortFolder { folder in
            let path = folder.appending(path: "c.sock").path
            // A socket file left behind: bound, then closed without being removed.
            ConsoleSocket.close(try ConsoleSocket.listen(at: path).descriptor)
            let run = try await VMR.vmr(["control", "status", "--socket", path, "--json"], in: folder)
            #expect(run.status == 69, "\(run.combined)")
            #expect(run.error.contains("nothing serves \(path)"), "\(run.error)")
            let object = try #require(try JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any])
            #expect(object["listening"] as? Bool == false)
        }
    }

    @Test
    func aTokenThatCouldNotBeCheckedIsNotReportedAsAbsent() async throws {
        try await withShortFolder { folder in
            let file = folder.appending(path: "token")
            try Data("vmrc_secret\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let run = try await VMR.vmr(
                ["control", "status", "--socket", folder.appending(path: "none.sock").path, "--token-file", file.path, "--json"], in: folder
            )
            #expect(run.status == 69, "\(run.combined)")
            #expect(run.output.contains(#""token":"unchecked""#), "\(run.output)")
            #expect(!run.combined.contains("vmrc_secret"))
        }
    }

    @Test
    func aTokenFileOpenToOtherUsersIsRefusedBeforeAnythingIsSent() async throws {
        try await withShortFolder { folder in
            let file = folder.appending(path: "token")
            try Data("vmrc_secret\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            let run = try await VMR.vmr(
                ["control", "status", "--socket", folder.appending(path: "c.sock").path, "--token-file", file.path], in: folder)
            #expect(run.status == 77, "\(run.combined)")
            #expect(run.error.contains("open to other users"), "\(run.error)")
            #expect(!run.combined.contains("vmrc_secret"))
        }
    }

    @Test
    func aTokenCannotBeGivenAsAnArgument() async throws {
        try await withShortFolder { folder in
            let run = try await VMR.vmr(["control", "status", "--token", "vmrc_secret"], in: folder)
            #expect(run.status == 64, "\(run.combined)")
        }
    }
}
