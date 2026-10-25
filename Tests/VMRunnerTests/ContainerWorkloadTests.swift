import Foundation
import TestKit
import Testing

@testable import VMRunner

/// A runner stand-in: a shell script the test writes to its own scratch folder. Nothing here starts a container or the real
/// runner.
private struct Script {
    let directory: URL
    let executable: URL

    init(_ body: String) throws {
        directory = try scratchDirectory()
        executable = directory.appending(path: "runner.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// A runner that prints `lines` (one event each), then runs `tail`.
    static func printing(_ lines: [String], then tail: String = "exit 0") throws -> Self {
        try Self("cat <<'EOF'\n" + lines.joined(separator: "\n") + "\nEOF\n" + tail)
    }

    static let boot = #"{"event":"phase","name":"boot","seconds":0.5}"#
    static let ready = #"{"event":"phase","name":"run","seconds":0}"#
    static let hello = #"{"event":"output","stream":"stdout","text":"hello\n"}"#

    /// Says it is ready, then waits for a `stop` line (exit 75) or the end of its input (exit 76).
    static let waitsForStop = "echo '\(ready)'\nread line || exit 76\n[ \"$line\" = stop ] && exit 75\nexit 1"
    /// Says it is ready, ignores its input and SIGTERM, then sleeps: only SIGKILL ends it.
    static let ignoresEverything = "trap '' TERM\necho '\(ready)'\nexec sleep 30"
}

/// The workload on its own: how the runner's events and exit become the controller's reports.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ContainerWorkloadTests {
    @MainActor
    private struct Rig {
        let script: Script
        let clock = TestClock()
        let workload: ContainerWorkload
        /// `stopped` and `error: <message>`, in the order the workload reported them.
        let reports = AsyncEventProbe<String>()

        init(_ script: Script) {
            self.script = script
            let process = ContainerProcess(
                executable: script.executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"], clock: clock,
                registry: ContainerProcesses())
            workload = ContainerWorkload(process: process, scratch: script.directory.appending(path: "scratch"))
            let reports = reports
            workload.onGuestStopped = { reports.record("stopped") }
            workload.onStoppedWithError = { reports.record("error: \($0)") }
        }

        func settle() async throws -> [String] { try await reports.wait(forAtLeast: 1) }
    }

    @Test func aWorkloadHasNoScreenPauseSuspendOrNetworkSwitch() throws {
        let rig = Rig(try Script("exit 0"))
        defer { rig.script.remove() }
        #expect(rig.workload.capabilities.isEmpty)
        #expect(rig.workload.networkCutoff == nil)
        #expect(!rig.workload.canStop)
    }

    @Test(arguments: [0, 75] as [Int])
    func aRunnerThatPassedOrWasStoppedEndsTheMachineCleanly(status: Int) async throws {
        let rig = Rig(
            try Script.printing([Script.boot, Script.hello, #"{"event":"finished","status":\#(status)}"#], then: "exit \(status)"))
        defer { rig.script.remove() }
        try await rig.workload.start()
        #expect(try await rig.settle() == ["stopped"])
        #expect(rig.workload.workloadLog?.output.text == "hello\n")
        #expect(!rig.workload.canStop)
    }

    @Test func aRunnerThatEndsWithoutSayingAnythingAfterExitingCleanlyIsStopped() async throws {
        let rig = Rig(try Script("exit 0"))
        defer { rig.script.remove() }
        try await rig.workload.start()
        #expect(try await rig.settle() == ["stopped"])
    }

    @Test func aContainerThatFailedEndsTheMachineWithItsStatus() async throws {
        let rig = Rig(
            try Script.printing(
                [Script.boot, #"{"event":"exited","status":3}"#, #"{"event":"finished","status":1}"#], then: "exit 1"))
        defer { rig.script.remove() }
        try await rig.workload.start()
        #expect(try await rig.settle() == ["error: The container exited with status 3."])
    }

    @Test func aRunnerFailureAfterTheStartUsesTheRunnersLastError() async throws {
        let rig = Rig(
            try Script.printing(
                [
                    Script.boot, #"{"event":"error","message":"first"}"#, #"{"event":"error","message":"the guest agent died"}"#,
                    #"{"event":"finished","status":70}"#,
                ], then: "exit 70"))
        defer { rig.script.remove() }
        try await rig.workload.start()
        #expect(try await rig.settle() == ["error: the guest agent died"])
    }

    @Test func aRunnerFailureWithoutAnErrorNamesItsStatus() async throws {
        let rig = Rig(try Script.printing([Script.boot], then: "exit 70"))
        defer { rig.script.remove() }
        try await rig.workload.start()
        #expect(try await rig.settle() == ["error: The container runner stopped with status 70."])
    }

    @Test func aRunnerThatFailsBeforeTheContainerIsUpFailsTheStartAndReportsNothingElse() async throws {
        let rig = Rig(
            try Script.printing(
                [#"{"event":"phase","name":"pull","seconds":1}"#, #"{"event":"error","message":"pull failed"}"#], then: "exit 70"))
        defer { rig.script.remove() }
        await #expect(throws: ContainerProcessError(reason: "pull failed")) { try await rig.workload.start() }
        #expect(rig.reports.events.isEmpty)
        #expect(rig.workload.workloadLog?.phases == [.init(name: "pull", seconds: 1)])
    }

    @Test func aRunnerEndedBySomeoneElseIsAFailure() async throws {
        let rig = Rig(try Script("kill -TERM $$"))
        defer { rig.script.remove() }
        await #expect(throws: ContainerProcessError(reason: "The container runner was ended by signal 15.")) {
            try await rig.workload.start()
        }
    }

    @Test func theFirstOutputIsEnoughToBeUp() async throws {
        let rig = Rig(try Script.printing([Script.hello], then: "read line"))
        defer { rig.script.remove() }
        try await rig.workload.start()
        #expect(rig.workload.canStop)
        try rig.workload.requestStop()
        #expect(try await rig.settle() == ["stopped"])
    }

    @Test func aRequestedStopSendsTheStopLineAndEndsTheMachineCleanly() async throws {
        let rig = Rig(try Script(Script.waitsForStop))
        defer { rig.script.remove() }
        try await rig.workload.start()
        #expect(rig.workload.canStop)
        try rig.workload.requestStop()
        #expect(try await rig.settle() == ["stopped"], "75 only follows the stop line; the end of input would be 76")
        #expect(!rig.workload.canStop)
        #expect(throws: ContainerProcessError.self) { try rig.workload.requestStop() }
    }

    @Test func aStopTheRunnerIgnoresEndsBySignalAndIsStillAStop() async throws {
        let rig = Rig(try Script(Script.ignoresEverything))
        defer { rig.script.remove() }
        try await rig.workload.start()
        try rig.workload.requestStop()
        try await rig.clock.waitForSleepers(atLeast: 1)
        rig.clock.advance(by: .seconds(10))
        try await rig.clock.waitForSleepers(atLeast: 1)
        rig.clock.advance(by: .seconds(5))
        #expect(try await rig.settle() == ["stopped"])
    }

    @Test func pullingThePlugKillsTheRunnerAndWaitsForItsEnd() async throws {
        let rig = Rig(try Script(Script.ignoresEverything))
        defer { rig.script.remove() }
        try await rig.workload.start()
        try await rig.workload.stop()
        #expect(!rig.workload.canStop)
        #expect(try await rig.settle() == ["stopped"])
        try await rig.workload.stop()
    }

    @Test func theWorkingFolderIsPrivate() async throws {
        let rig = Rig(try Script(Script.waitsForStop))
        defer { rig.script.remove() }
        try await rig.workload.start()
        let scratch = rig.script.directory.appending(path: "scratch")
        let permissions = try FileManager.default.attributesOfItem(atPath: scratch.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        try rig.workload.requestStop()
        _ = try await rig.settle()
    }
}

/// The machine as the app drives it: the library, the controller and the routing factory, with a script for the runner.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ContainerMachineRunTests {
    @MainActor
    private struct Machine {
        let directory: URL
        let library: VMLibrary
        let controller: VMController
        let config: VMConfig

        /// `runner` is the script a start runs, or nil for a runner that is not there.
        init(runner: Script?, spec: ContainerSpec = ContainerSpec()) throws {
            directory = try scratchDirectory()
            let machines = directory.appending(path: "Machines", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
            let router = RoutingMachineFactory(
                virtualMachines: FakeFactory(),
                containers: ContainerMachineFactory(runner: runner?.executable ?? directory.appending(path: "absent")))
            let controller = VMController(
                factory: router, latency: LatencyActivity(host: ProcessInfo.processInfo, isEnabled: false))
            self.controller = controller
            library = VMLibrary(machinesDirectory: machines, saveDelay: .seconds(3600), makeController: { controller })
            let proposed = VMConfig.newContainer(name: "box", container: spec)
            try library.add(proposed)
            config = library.machine(proposed.id) ?? proposed
        }

        var id: UUID { config.id }
        var bundle: VMBundle { library.bundle(id) }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).sorted() }

        /// Calls made when the workload reports it stopped, after the controller has handled the report.
        func watchStops() throws -> AsyncEventProbe<String> {
            let workload = try #require(controller.guest as? ContainerWorkload)
            let probe = AsyncEventProbe<String>()
            let stopped = workload.onGuestStopped
            let failed = workload.onStoppedWithError
            workload.onGuestStopped = {
                stopped?()
                probe.record("stopped")
            }
            workload.onStoppedWithError = {
                failed?($0)
                probe.record("error")
            }
            return probe
        }
    }

    @Test func aMissingOrUnusableRunnerFailsTheStartWithAClearMessageAndLeavesTheMachineStopped() async throws {
        let absent = try Machine(runner: nil)
        defer { absent.remove() }
        let notExecutable = try Script("exit 0")
        defer { notExecutable.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notExecutable.executable.path)
        let unusable = try Machine(runner: notExecutable)
        defer { unusable.remove() }

        for machine in [absent, unusable] {
            let result = await machine.library.startAndWait(machine.id)
            #expect(result == .failed(ContainerMachineFactory.missingRunnerMessage))
            #expect(machine.controller.state == .stopped)
            #expect(machine.controller.guest == nil)
            #expect(try machine.names() == ["config.json"])
        }
        #expect(ContainerMachineFactory.missingRunnerMessage.contains("vmr build-app"))
    }

    @Test func aContainerMachineStartsShowsItsLogAndStopsOnRequest() async throws {
        let script = try Script(
            "echo '\(Script.boot)'\nprintf '{\"event\":\"output\",\"stream\":\"stdout\",\"text\":\"%s\"}\\n' \"$*\"\n"
                + "echo '\(Script.ready)'\nread line || exit 76\n[ \"$line\" = stop ] && exit 75\nexit 1")
        defer { script.remove() }
        let spec = ContainerSpec(
            image: "example.test/tool:1", command: ["run"], environment: [ContainerEnvironmentEntry(name: "A", value: "b")],
            cpus: 3, memoryMiB: 256, network: .loopback)
        let machine = try Machine(runner: script, spec: spec)
        defer { machine.remove() }

        #expect(await machine.library.startAndWait(machine.id) == .done(.running))
        #expect(machine.controller.errorMessage == nil)
        #expect(!machine.controller.canPause && !machine.controller.canSuspend)
        let model = machine.library.model(for: machine.id)
        #expect(model.isContainer)
        let workload = try #require(machine.controller.guest as? ContainerWorkload)
        guard case .running(.workloadLog(let shown)) = model.phase else {
            Issue.record("expected the log pane, got \(String(describing: model.phase))")
            return
        }
        #expect(shown === workload.workloadLog)
        let permissions = try FileManager.default.attributesOfItem(atPath: machine.bundle.containerScratch.path)[.posixPermissions]
        #expect(permissions as? Int == 0o700)

        let stops = try machine.watchStops()
        machine.controller.requestStop()
        #expect(machine.controller.state == .shuttingDown)
        _ = try await stops.wait(forAtLeast: 1)

        #expect(stops.events == ["stopped"])
        #expect(machine.controller.state == .stopped)
        #expect(machine.controller.errorMessage == nil, "exit 75 is a stop, not an error")
        #expect(machine.controller.guest == nil)
        guard case .editing = model.phase else {
            Issue.record("expected the settings pane after the stop")
            return
        }
        let output = shown.output.text
        let expectedArguments =
            "\(machine.bundle.containerScratch.path) --json --image example.test/tool:1 --cpus 3 --memory 256 --network loopback"
            + " --env A=b --command run"
        #expect(output == expectedArguments)
        #expect(shown.phases.map(\.name) == ["boot", "run"])
        // None of a virtual machine's start happened: the configuration is as it was and the bundle holds no disk or state.
        #expect(machine.library.machine(machine.id) == machine.config)
        #expect(try machine.names() == ["config.json", "container-scratch"])
    }

    @Test func aRunnerThatFailsBeforeTheContainerRunsLeavesTheMachineStoppedWithItsMessage() async throws {
        let script = try Script.printing(
            [#"{"event":"error","message":"pull failed"}"#, #"{"event":"finished","status":70}"#], then: "exit 70")
        defer { script.remove() }
        let machine = try Machine(runner: script)
        defer { machine.remove() }

        #expect(await machine.library.startAndWait(machine.id) == .failed("pull failed"))
        #expect(machine.controller.state == .stopped)
        #expect(machine.controller.guest == nil)
    }

    @Test func forceStopPullsThePlugWithoutAnError() async throws {
        let script = try Script(Script.ignoresEverything)
        defer { script.remove() }
        let machine = try Machine(runner: script)
        defer { machine.remove() }

        #expect(await machine.library.startAndWait(machine.id) == .done(.running))
        await machine.controller.forceStop()

        #expect(machine.controller.state == .stopped)
        #expect(machine.controller.errorMessage == nil)
        #expect(machine.controller.guest == nil)
        #expect(await machine.library.stopAndWait(machine.id, force: true) == .refused("“box” is not running."))
    }

    @Test func aMachineStartedFromTheMenuGoesThroughTheSamePath() async throws {
        let script = try Script(Script.waitsForStop)
        defer { script.remove() }
        let machine = try Machine(runner: script)
        defer { machine.remove() }

        machine.library.startMachine(machine.id, interactive: false)
        #expect(machine.library.alertMessage == nil)
        while machine.controller.state != .running { await Task.yield() }
        let stops = try machine.watchStops()
        machine.controller.requestStop()
        _ = try await stops.wait(forAtLeast: 1)
        #expect(machine.controller.state == .stopped)
        #expect(machine.library.runningCount == 0)
    }
}
