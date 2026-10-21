import Foundation
import Testing

@testable import DevTools

/// The process layer over swift-subprocess: capture, environment, working directory, timeout.
struct ProcessRunnerTests {
    @Test
    func capturesBothStreamsAndTheExitStatus() async throws {
        let spec = CommandSpec(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
        let result = try await ProcessRunner.run(spec)
        #expect(result.status == 3)
        #expect(result.standardOutput == "out\n")
        #expect(result.standardError == "err\n")
        #expect(!result.succeeded)
    }

    @Test
    func passesTheEnvironmentAndWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let spec = CommandSpec(
            executable: "/bin/sh",
            arguments: ["-c", "echo $VMR_PROBE; pwd"],
            workingDirectory: directory,
            environment: ["VMR_PROBE": "set"],
            inheritEnvironment: false
        )
        let result = try await ProcessRunner.run(spec)
        let lines = result.standardOutput.split(separator: "\n").map(String.init)
        #expect(lines.first == "set")
        // /var and /private/var are the same directory; compare after the same normalization.
        #expect(lines.last.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == directory.path)
    }

    @Test
    func aSignalShowsAsAShellStatus() async throws {
        let result = try await ProcessRunner.run(CommandSpec(executable: "/bin/sh", arguments: ["-c", "kill -9 $$"]))
        #expect(result.status == 128 + 9)
    }

    @Test
    func aProcessThatOutlivesItsTimeoutIsTerminated() async throws {
        let started = ContinuousClock.now
        let spec = CommandSpec(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300))
        let result = try await ProcessRunner.run(spec)
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(started.duration(to: .now) < .seconds(20), "SIGTERM ends the sleep long before it would finish")
    }

    @Test
    func aFastProcessIsNotTimedOut() async throws {
        let result = try await ProcessRunner.run(CommandSpec(executable: "/usr/bin/true", timeout: .seconds(60)))
        #expect(result.succeeded)
        #expect(!result.timedOut)
    }

    @Test
    func aMissingProgramIsReportedByName() async {
        let spec = CommandSpec(executable: "definitely-not-installed", environment: ["PATH": "/usr/bin"])
        await #expect(throws: ToolError.self) { try await ProcessRunner.run(spec) }
    }
}
