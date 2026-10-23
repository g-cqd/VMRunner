import Foundation
import GuestConsole
import Testing

@testable import DevTools

/// The real `vmr guest` binary against a console served by the real bridge, with a fake guest behind it.
struct GuestCommandTests {
    /// A short private directory: a local socket path holds about 100 bytes, and the usual temporary path is too long.
    private func withConsole<Value>(_ body: (_ socket: String, _ directory: URL) async throws -> Value) async throws -> Value {
        let directory = URL(filePath: "/tmp/vmr-gc-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = try FakeGuestConsole(socketPath: directory.appending(path: "c.sock").path)
        do {
            let result = try await body(guest.socket, directory)
            await guest.shutDown()
            return result
        } catch {
            await guest.shutDown()
            throw error
        }
    }

    @Test
    func execLogsInRunsTheCommandPrintsItsOutputAndExitsZero() async throws {
        try await withConsole { socket, directory in
            let run = try await VMR.vmr(["guest", "exec", socket, "--", "uname", "-a"], in: directory)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output == "Linux localhost 6.18.52-0-virt aarch64 Linux\n")
        }
    }

    @Test
    func execExitsWithTheGuestCommandsOwnStatusAndStillPrintsItsOutput() async throws {
        try await withConsole { socket, directory in
            let failing = try await VMR.vmr(["guest", "exec", socket, "--", "fail"], in: directory)
            #expect(failing.status == 3)
            #expect(failing.output == "it failed\n")
            let missing = try await VMR.vmr(["guest", "exec", socket, "--", "nosuchprogram"], in: directory)
            #expect(missing.status == 127)
            #expect(missing.output == "sh: nosuchprogram: not found\n")
        }
    }

    @Test
    func severalCommandsInARowEachGetTheirOwnAnswer() async throws {
        try await withConsole { socket, directory in
            for round in 0..<6 {
                let command = round.isMultiple(of: 2) ? "uname -a" : "fail"
                let run = try await VMR.vmr(["guest", "exec", socket, "--", command], in: directory)
                #expect(run.status == (round.isMultiple(of: 2) ? 0 : 3), "round \(round): \(run.combined)")
            }
        }
    }

    @Test
    func execThatRunsOutOfTimeExits124AndSaysWhatItWaitedFor() async throws {
        try await withConsole { socket, directory in
            let run = try await VMR.vmr(["guest", "exec", socket, "--timeout", "1", "--", "hang"], in: directory)
            #expect(run.status == 124)
            #expect(run.error.contains("timed out waiting for the command to finish"), "\(run.error)")
        }
    }

    @Test
    func execWithNothingServingTheSocketExits125AndSaysSo() async throws {
        try await withTemporaryDirectory { directory in
            let run = try await VMR.vmr(["guest", "exec", "/tmp/vmr-no-such-console.sock", "--", "uname"], in: directory)
            #expect(run.status == 125)
            #expect(run.error.contains("nothing is serving"), "\(run.error)")
        }
    }

    @Test
    func execWithoutACommandIsAUsageError() async throws {
        try await withTemporaryDirectory { directory in
            let run = try await VMR.vmr(["guest", "exec", "/tmp/x.sock"], in: directory)
            #expect(run.status == 64)
            #expect(run.combined.contains("command"), "\(run.combined)")
        }
    }

    @Test
    func startRefusesAPlanAboveTheCapsBeforeTouchingAnything() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = directory.appending(path: "scratch")
            for flags in [["--cpus", "3"], ["--memory-mib", "4096"]] {
                let run = try await VMR.vmr(
                    ["guest", "start", "--root", directory.path, "--directory", scratch.path] + flags, in: directory)
                #expect(run.status == 64, "\(flags): \(run.combined)")
                #expect(run.combined.contains("must be from"), "\(run.combined)")
            }
            #expect(!FileManager.default.fileExists(atPath: scratch.path), "nothing was created")
        }
    }

    @Test
    func everyGuestCommandRefusesTheLibraryAsAScratchDirectory() async throws {
        try await withTemporaryDirectory { directory in
            let library = FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Library/Application Support/VMRunner/vmr-guest-test")
            let commands = [
                ["fetch", "alpine-netboot", "--directory", library.path], ["stop", "--directory", library.path],
                ["start", "--root", directory.path, "--directory", library.path],
            ]
            for command in commands {
                let run = try await VMR.vmr(["guest"] + command, in: directory)
                #expect(run.status == 1, "\(command): \(run.combined)")
                #expect(run.error.contains("inside your Library"), "\(command): \(run.error)")
            }
            #expect(!FileManager.default.fileExists(atPath: library.path), "nothing was created there")
        }
    }

    @Test
    func consoleWithRawWarnsOnStandardErrorAndWithoutItDoesNot() async throws {
        try await withTemporaryDirectory { directory in
            let socket = "/tmp/vmr-no-such-console.sock"
            let raw = try await VMR.vmr(["guest", "console", "--raw", socket], in: directory)
            #expect(raw.status == 125, "\(raw.combined)")
            #expect(raw.error.contains(ConsoleAttach.rawWarning), "\(raw.error)")
            let filtered = try await VMR.vmr(["guest", "console", socket], in: directory)
            #expect(filtered.status == 125, "\(filtered.combined)")
            #expect(filtered.error.contains("nothing is serving"), "\(filtered.error)")
            #expect(!filtered.error.contains("warning"), "\(filtered.error)")
        }
    }

    @Test
    func consoleHelpOffersRaw() async throws {
        try await withTemporaryDirectory { directory in
            let help = try await VMR.vmr(["guest", "console", "--help"], in: directory)
            #expect(help.status == 0, "\(help.combined)")
            #expect(help.output.contains("--raw"), "\(help.output)")
        }
    }
}
