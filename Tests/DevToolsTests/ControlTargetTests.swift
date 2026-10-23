import Foundation
import Testing

@testable import DevTools

/// Where `vmr control` looks for the socket and the token, without a process or a service. No test reads the user's own
/// data folder: the default is computed for a made-up home folder.
struct ControlTargetTests {
    private let current = URL(fileURLWithPath: "/work", isDirectory: true)
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test
    func theSocketOptionWinsAndIsResolvedAgainstTheCurrentFolder() throws {
        let environment = ["VMRUNNER_DATA_DIR": "/tmp/data"]
        #expect(
            try ControlTarget.socketPath("/tmp/a.sock", environment: environment, home: home, currentDirectory: current) == "/tmp/a.sock")
        #expect(
            try ControlTarget.socketPath("b/c.sock", environment: environment, home: home, currentDirectory: current) == "/work/b/c.sock")
    }

    @Test
    func theDataFolderVariableMovesTheDefaultSocket() throws {
        let path = try ControlTarget.socketPath(
            nil, environment: ["VMRUNNER_DATA_DIR": "/tmp/data/"], home: home, currentDirectory: current)
        #expect(path == "/tmp/data/Control/control.sock")
    }

    @Test
    func withoutTheVariableTheSocketIsInTheAppsDataFolder() throws {
        for environment in [[:], ["VMRUNNER_DATA_DIR": ""]] {
            let path = try ControlTarget.socketPath(nil, environment: environment, home: home, currentDirectory: current)
            #expect(path == "/Users/someone/Library/Application Support/VMRunner/Control/control.sock")
        }
    }

    @Test(arguments: ["relative/data", "/tmp/../Users/someone"])
    func aDataFolderVariableTheAppWouldRefuseIsAUsageError(value: String) {
        let error = #expect(throws: ToolError.self) {
            try ControlTarget.socketPath(nil, environment: ["VMRUNNER_DATA_DIR": value], home: home, currentDirectory: current)
        }
        #expect(error?.status == ToolError.usageStatus)
    }

    @Test
    func theTokenComesFromTheVariableWhenNoFileIsGiven() throws {
        let token = try ControlTarget.token(file: nil, environment: ["VMR_CONTROL_TOKEN": " vmrc_abc\n"], currentDirectory: current)
        #expect(token == "vmrc_abc")
        #expect(try ControlTarget.token(file: nil, environment: [:], currentDirectory: current) == nil)
    }

    @Test
    func aPrivateTokenFileWinsOverTheVariable() async throws {
        try await withTemporaryDirectory { directory in
            let file = try Self.tokenFile("vmrc_fromfile\n", mode: 0o600, in: directory)
            let token = try ControlTarget.token(
                file: file.path, environment: ["VMR_CONTROL_TOKEN": "vmrc_fromvariable"], currentDirectory: current)
            #expect(token == "vmrc_fromfile")
        }
    }

    @Test(arguments: [0o644, 0o640, 0o604, 0o660])
    func aTokenFileOtherUsersMayReadOrWriteIsRefused(mode: Int) async throws {
        try await withTemporaryDirectory { directory in
            let file = try Self.tokenFile("vmrc_secret\n", mode: mode, in: directory)
            let error = #expect(throws: ToolError.self) {
                try ControlTarget.token(file: file.path, environment: [:], currentDirectory: current)
            }
            #expect(error?.status == ControlExit.notPermitted)
            #expect(error?.message.contains("chmod 600") == true)
            #expect(error?.message.contains("vmrc_secret") == false, "the token is never repeated")
        }
    }

    @Test
    func aMissingTokenFileOrALinkIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            let missing = #expect(throws: ToolError.self) {
                try ControlTarget.token(file: directory.appending(path: "none").path, environment: [:], currentDirectory: current)
            }
            #expect(missing?.status == ControlExit.noInput)
            let target = try Self.tokenFile("vmrc_secret\n", mode: 0o600, in: directory)
            let link = directory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let linked = #expect(throws: ToolError.self) {
                try ControlTarget.token(file: link.path, environment: [:], currentDirectory: current)
            }
            #expect(linked?.status == ControlExit.noInput)
        }
    }

    @Test
    func textThatIsNotATokenIsAUsageError() async throws {
        try await withTemporaryDirectory { directory in
            let file = try Self.tokenFile("password\n", mode: 0o600, in: directory)
            let error = #expect(throws: ToolError.self) {
                try ControlTarget.token(file: file.path, environment: [:], currentDirectory: current)
            }
            #expect(error?.status == ToolError.usageStatus)
        }
    }

    private static func tokenFile(_ text: String, mode: Int, in directory: URL) throws -> URL {
        let file = directory.appending(path: "token")
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }
}
