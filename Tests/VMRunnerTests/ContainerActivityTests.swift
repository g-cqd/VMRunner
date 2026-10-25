import Foundation
import TestKit
import Testing

@testable import VMRunner

/// Stands in for the process: records which activities began and ended instead of telling the system.
private final class SpyHost: ActivityHost {
    private(set) var begun: [ProcessInfo.ActivityOptions] = []
    private(set) var ended = 0

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol {
        begun.append(options)
        return NSObject()
    }

    func endActivity(_ activity: any NSObjectProtocol) { ended += 1 }
}

/// A runner stand-in: the shell script `body` in a scratch folder of its own. Nothing here starts a container or the real runner.
private func writeRunner(_ body: String) throws -> URL {
    let script = try scratchDirectory().appending(path: "runner.sh")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

private let readyLine = #"echo '{"event":"phase","name":"run","seconds":0}'"#
/// Says it is ready, then waits for a `stop` line (exit 75) or the end of its input (exit 76).
private let waitsForStop = readyLine + "\nread line || exit 76\n[ \"$line\" = stop ] && exit 75\nexit 1"

/// The activity a container machine holds while its runner lives (App Nap would coalesce the timers that carry the stop's
/// time limits).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ContainerActivityTests {
    private let host = SpyHost()

    /// A workload on the runner `script`, with its own registry and a test clock, so no real timer runs.
    private func makeWorkload(_ script: URL) -> ContainerWorkload {
        let process = ContainerProcess(
            executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"], clock: TestClock(),
            registry: ContainerProcesses())
        return ContainerWorkload(process: process, scratch: script.deletingLastPathComponent().appending(path: "scratch"), host: host)
    }

    @Test func theActivityIsUserInitiatedAndDoesNotKeepTheMacAwakeOrAskForLatency() {
        let options = ContainerWorkload.activityOptions
        #expect(options.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(!options.contains(.latencyCritical))
        #expect(!options.contains(.idleSystemSleepDisabled))
    }

    @Test func aRunningContainerHoldsOneActivityUntilItsRunnerEnds() async throws {
        let script = try writeRunner(waitsForStop)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let workload = makeWorkload(script)
        let stopped = AsyncEventProbe<String>()
        workload.onGuestStopped = { stopped.record("stopped") }

        try await workload.start()
        #expect(host.begun == [ContainerWorkload.activityOptions])
        #expect(host.ended == 0)

        try workload.requestStop()
        _ = try await stopped.wait(forAtLeast: 1)
        #expect(host.begun.count == 1)
        #expect(host.ended == 1)
    }

    @Test func aStartThatThrowsHoldsNothing() async throws {
        let script = try writeRunner("exit 0")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let workload = makeWorkload(script.deletingLastPathComponent().appending(path: "absent"))

        await #expect(throws: ContainerProcessError.self) { try await workload.start() }
        #expect(host.begun.isEmpty)
        #expect(host.ended == 0)
    }

    @Test func aRunnerThatFailsBeforeItIsReadyEndsTheActivityItBegan() async throws {
        let script = try writeRunner(#"echo '{"event":"error","message":"pull failed"}'"# + "\nexit 70")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let workload = makeWorkload(script)

        await #expect(throws: ContainerProcessError(reason: "pull failed")) { try await workload.start() }
        #expect(host.begun.count == 1)
        #expect(host.ended == 1)
    }

    @Test func aWorkloadReleasedWhileItsRunnerRunsEndsItsActivity() async throws {
        let script = try writeRunner(waitsForStop)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        var workload: ContainerWorkload? = makeWorkload(script)
        try await workload?.start()
        #expect(host.begun.count == 1)
        #expect(host.ended == 0)

        // The process goes with the workload, and its release kills the runner.
        workload = nil
        #expect(host.ended == 1)
    }
}
