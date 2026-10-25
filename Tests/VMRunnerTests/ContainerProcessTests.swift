import Darwin
import Foundation
import Synchronization
import TestKit
import Testing

@testable import VMRunner

/// A runner stand-in: a shell script the test writes to its own scratch folder. Nothing here starts a container or the real
/// runner.
private struct FakeRunner {
    let directory: URL
    let executable: URL

    /// Writes `body` as an executable script (mode 0700).
    init(_ body: String) throws {
        directory = try scratchDirectory()
        executable = directory.appending(path: "runner.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    /// The file a script writes its own or its background child's pid to.
    var pidFile: URL { URL(fileURLWithPath: executable.path + ".pid") }

    /// Ends the process whose pid the script wrote, when it wrote one, and removes the scratch folder.
    func remove() {
        if let pid = writtenPid { _ = Darwin.kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The pid the script wrote to its pid file, when it did.
    var writtenPid: Int32? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A runner that prints `lines` (one event each) and exits with `status`.
    static func printing(_ lines: [String], then tail: String = "exit 0") throws -> Self {
        let script = "cat <<'EOF'\n" + lines.joined(separator: "\n") + "\nEOF\n" + tail
        return try Self(script)
    }

    /// Says it is ready (a phase event), then waits for a `stop` line (exit 75) or the end of its input (exit 76).
    static let waitsForStop =
        "echo '{\"event\":\"phase\",\"name\":\"run\",\"seconds\":0}'\nread line || exit 76\n[ \"$line\" = stop ] && exit 75\nexit 1"
    /// Ignores its input and sleeps; SIGTERM ends it.
    static let sleeps = "exec sleep 30"
    /// Exits at once but leaves a background child that holds the output pipes open; the test ends it with `remove()`.
    static let leavesOutputOpen = "sleep 60 &\necho $! > \"$0.pid\"\nexit 0"
    /// Ignores its input and SIGTERM, says it is ready, then sleeps: only SIGKILL ends it.
    static let ignoresTerm = "trap '' TERM\necho '{\"event\":\"phase\",\"name\":\"run\",\"seconds\":0}'\nexec sleep 30"
}

/// Records `1` in `probe` when the process `pid` exits. (Not isolated: a handler made on the main actor would be asserted to run
/// there.)
private nonisolated func watchExit(of pid: Int32, into probe: AsyncEventProbe<Int>) -> any DispatchSourceProcess {
    let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
    watcher.setEventHandler { probe.record(1) }
    watcher.activate()
    return watcher
}

/// A pausable reader stand-in that counts how often it was paused and resumed.
private final class CountingReader: Pausable {
    private let counts = Mutex((paused: 0, resumed: 0))
    var paused: Int { counts.withLock { $0.paused } }
    var resumed: Int { counts.withLock { $0.resumed } }
    func pause() { counts.withLock { $0.paused += 1 } }
    func resume() { counts.withLock { $0.resumed += 1 } }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ContainerProcessTests {
    private func make(
        _ runner: FakeRunner, arguments: [String] = [], clock: any Clock<Duration> = TestClock(),
        registry: ContainerProcesses = ContainerProcesses(), environment: [String: String] = ["PATH": "/usr/bin:/bin"]
    ) -> ContainerProcess {
        ContainerProcess(
            executable: runner.executable, arguments: arguments, environment: environment, clock: clock, registry: registry)
    }

    @Test func aRunAppliesEveryEventToTheLogBeforeItReportsTheEnd() async throws {
        let runner = try FakeRunner.printing(
            [
                #"{"event":"phase","name":"pull","seconds":1.5,"time":1}"#,
                "this is not json",
                #"{"event":"progress","time":1}"#,
                #"{"event":"output","stream":"stdout","text":"\u001b]0;evil\u0007hello \u001b[31mred\u001b[0m\n","time":2}"#,
                #"{"event":"output","stream":"stderr","text":"oops\n","time":2}"#,
                #"{"event":"exited","status":3,"time":3}"#,
                #"{"event":"finished","status":1,"time":3}"#,
            ], then: "echo 'runner diagnostics' >&2\nexit 1")
        defer { runner.remove() }
        let process = make(runner)
        var reported: [ContainerExit] = []
        process.onExit = { reported.append($0) }
        try process.start()
        let exit = await process.waitForExit()
        #expect(exit == ContainerExit(status: 1, signaled: false))
        #expect(reported == [exit])
        #expect(process.exit == exit)
        #expect(process.isRunning == false)
        let log = process.log
        #expect(log.phases == [.init(name: "pull", seconds: 1.5)])
        #expect(log.output.text == "hello \u{1B}[31mred\u{1B}[0m\noops\n")
        #expect(log.containerStatus == 3)
        #expect(log.finishedStatus == 1)
        #expect(log.ignoredLines == 2)
        #expect(log.droppedLines == 0)
        #expect(log.diagnostics.text == "runner diagnostics\n")
    }

    @Test func eventsReachTheObserverInOrder() async throws {
        let runner = try FakeRunner.printing(
            [
                #"{"event":"phase","name":"kernel","seconds":0}"#, #"{"event":"phase","name":"boot","seconds":0}"#,
                #"{"event":"exited","status":0}"#, #"{"event":"finished","status":0}"#,
            ])
        defer { runner.remove() }
        let process = make(runner)
        var events: [ContainerEvent] = []
        process.onEvent = { events.append($0) }
        try process.start()
        _ = await process.waitForExit()
        #expect(
            events == [
                .phase(name: "kernel", seconds: 0), .phase(name: "boot", seconds: 0), .exited(status: 0), .finished(status: 0),
            ])
    }

    @Test func theArgumentsAndOnlyTheGivenEnvironmentReachTheRunner() async throws {
        let line = #"printf '{"event":"output","stream":"stdout","text":"%s|%s|%s"}\n' "$1" "$2" "${MARK-none}${HOME-nohome}""#
        let runner = try FakeRunner(line)
        defer { runner.remove() }
        let process = make(runner, arguments: ["first arg", "-x"], environment: ["PATH": "/usr/bin:/bin", "MARK": "m"])
        try process.start()
        _ = await process.waitForExit()
        #expect(process.log.output.text == "first arg|-x|mnohome")
    }

    @Test func aRequestedStopEndsARunnerThatHonoursIt() async throws {
        let runner = try FakeRunner(FakeRunner.waitsForStop)
        defer { runner.remove() }
        let clock = TestClock()
        let probe = AsyncEventProbe<ContainerEvent>()
        let process = make(runner, clock: clock)
        process.onEvent = { probe.record($0) }
        var reports = 0
        process.onExit = { _ in reports += 1 }
        try process.start()
        _ = try await probe.wait(forAtLeast: 1)
        #expect(process.isRunning)
        process.stop()
        process.stop()
        let exit = await process.waitForExit()
        #expect(exit == ContainerExit(status: 75, signaled: false))
        process.stop()
        process.kill()
        #expect(reports == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aRunnerThatIgnoresTheStopGetsSigtermAfterTheGrace() async throws {
        let runner = try FakeRunner(FakeRunner.sleeps)
        defer { runner.remove() }
        let clock = TestClock()
        let process = make(runner, clock: clock)
        try process.start()
        process.stop()
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(9))
        #expect(process.isRunning)
        clock.advance(by: .seconds(1))
        #expect(await process.waitForExit() == ContainerExit(status: SIGTERM, signaled: true))
    }

    @Test func aRunnerThatIgnoresSigtermGetsSigkillAfterTheSecondGrace() async throws {
        let runner = try FakeRunner(FakeRunner.ignoresTerm)
        defer { runner.remove() }
        let clock = TestClock()
        let probe = AsyncEventProbe<ContainerEvent>()
        let process = make(runner, clock: clock)
        process.onEvent = { probe.record($0) }
        try process.start()
        _ = try await probe.wait(forAtLeast: 1)
        process.stop()
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(10))
        try await clock.waitForSleepers(atLeast: 1)
        #expect(process.isRunning)
        clock.advance(by: .seconds(5))
        #expect(await process.waitForExit() == ContainerExit(status: SIGKILL, signaled: true))
    }

    @Test func killIsImmediateAndIdempotent() async throws {
        let runner = try FakeRunner(FakeRunner.sleeps)
        defer { runner.remove() }
        let process = make(runner)
        try process.start()
        process.kill()
        process.kill()
        #expect(await process.waitForExit() == ContainerExit(status: SIGKILL, signaled: true))
        process.kill()
        process.stop()
    }

    @Test func closingTheInputWithoutARequestIsTheEndOfInputTheRunnerSeesWhenTheAppDies() async throws {
        let runner = try FakeRunner(FakeRunner.waitsForStop)
        defer { runner.remove() }
        let process = Process()
        process.executableURL = runner.executable
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        let handle = try #require(RunnerHandle(process: process, stdin: input.fileHandleForWriting))
        try process.run()
        try input.fileHandleForReading.close()
        handle.closeStdin()
        process.waitUntilExit()
        #expect(process.terminationStatus == 76)
    }

    @Test func theInputIsNonBlockingAndAStopToARunnerThatIsGoneIsHarmless() throws {
        let runner = try FakeRunner("exit 0")
        defer { runner.remove() }
        let process = Process()
        process.executableURL = runner.executable
        let input = Pipe()
        process.standardInput = input
        let handle = try #require(RunnerHandle(process: process, stdin: input.fileHandleForWriting))
        #expect(fcntl(input.fileHandleForWriting.fileDescriptor, F_GETFL) & O_NONBLOCK != 0)
        try process.run()
        try input.fileHandleForReading.close()
        process.waitUntilExit()
        handle.requestStop()
        handle.requestStop()
        handle.terminate()
        handle.forceKill()
        #expect(!handle.isRunning)
    }

    @Test func aRunnerThatLeavesTheOutputOpenIsGivenUpAfterTheDrainGrace() async throws {
        let runner = try FakeRunner(FakeRunner.leavesOutputOpen)
        defer { runner.remove() }
        let clock = TestClock()
        let process = make(runner, clock: clock)
        try process.start()
        try await clock.waitForSleepers(atLeast: 1)
        #expect(process.exit == nil)
        clock.advance(by: .seconds(2))
        #expect(await process.waitForExit() == ContainerExit(status: 0, signaled: false))
        #expect(process.openDescriptorCount == 0)
    }

    @Test func aRunThatCannotStartThrowsAndLeavesNothingOpen() async throws {
        let runner = try FakeRunner("exit 0")
        defer { runner.remove() }
        let registry = ContainerProcesses()
        let missing = ContainerProcess(
            executable: runner.directory.appending(path: "absent"), arguments: [], registry: registry)
        #expect(throws: ContainerProcessError.self) { try missing.start() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runner.executable.path)
        let notExecutable = make(runner, registry: registry)
        #expect(throws: ContainerProcessError.self) { try notExecutable.start() }
        // Executable, but its interpreter does not exist: the system refuses after the pipes were opened.
        try Data("#!/nonexistent/interpreter\n".utf8).write(to: runner.executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.executable.path)
        let unlaunchable = make(runner, registry: registry)
        #expect(throws: ContainerProcessError.self) { try unlaunchable.start() }
        #expect(registry.liveCount == 0)
        for process in [missing, notExecutable, unlaunchable] {
            #expect(process.openDescriptorCount == 0)
            #expect(process.isRunning == false)
            #expect(await process.waitForExit() == .notStarted)
        }
    }

    @Test func aRunCannotBeStartedTwice() async throws {
        let runner = try FakeRunner("exit 0")
        defer { runner.remove() }
        let process = make(runner)
        try process.start()
        #expect(throws: ContainerProcessError.self) { try process.start() }
        _ = await process.waitForExit()
        #expect(throws: ContainerProcessError.self) { try process.start() }
    }

    @Test func noDescriptorSurvivesARunWhateverEndsIt() async throws {
        let finishing = try FakeRunner.printing([#"{"event":"finished","status":0}"#])
        let stopping = try FakeRunner(FakeRunner.waitsForStop)
        let killed = try FakeRunner(FakeRunner.sleeps)
        defer {
            finishing.remove()
            stopping.remove()
            killed.remove()
        }
        let registry = ContainerProcesses()
        let first = make(finishing, registry: registry)
        try first.start()
        #expect(first.openDescriptorCount > 0)
        _ = await first.waitForExit()
        let second = make(stopping, registry: registry)
        let probe = AsyncEventProbe<ContainerEvent>()
        second.onEvent = { probe.record($0) }
        try second.start()
        _ = try await probe.wait(forAtLeast: 1)
        second.stop()
        _ = await second.waitForExit()
        let third = make(killed, registry: registry)
        try third.start()
        third.kill()
        _ = await third.waitForExit()
        #expect(registry.liveCount == 0)
        for process in [first, second, third] { #expect(process.openDescriptorCount == 0) }
    }

    @Test func quittingStopsARunnerThatHonoursItAndKillsOneThatDoesNot() async throws {
        let polite = try FakeRunner(FakeRunner.waitsForStop)
        let stubborn = try FakeRunner(FakeRunner.sleeps)
        defer {
            polite.remove()
            stubborn.remove()
        }
        let registry = ContainerProcesses()
        let politeProcess = make(polite, registry: registry)
        let stubbornProcess = make(stubborn, registry: registry)
        let probe = AsyncEventProbe<ContainerEvent>()
        politeProcess.onEvent = { probe.record($0) }
        try politeProcess.start()
        try stubbornProcess.start()
        _ = try await probe.wait(forAtLeast: 1)
        #expect(registry.liveCount == 2)
        registry.terminateAll(timeout: .seconds(2))
        #expect(await politeProcess.waitForExit() == ContainerExit(status: 75, signaled: false))
        #expect(await stubbornProcess.waitForExit() == ContainerExit(status: SIGKILL, signaled: true))
        #expect(registry.liveCount == 0)
    }

    @Test func quittingWithNothingRunningDoesNothing() {
        ContainerProcesses().terminateAll(timeout: .zero, killWait: .zero)
    }
}

extension ContainerProcessTests {
    @Test func theDrainWaitStartsAgainWhileOutputIsWaitingToBeAppliedButOnlyFiveTimes() async throws {
        let runner = try FakeRunner(FakeRunner.leavesOutputOpen)
        defer { runner.remove() }
        let clock = TestClock()
        // Bytes that are counted as queued and never applied: the application is behind for good.
        let backlog = OutputBacklog()
        backlog.queued(1, from: CountingReader())
        let process = ContainerProcess(
            executable: runner.executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"], clock: clock,
            registry: ContainerProcesses(), backlog: backlog)
        try process.start()
        for _ in 0..<5 {
            try await clock.waitForSleepers(atLeast: 1)
            clock.advance(by: .seconds(2))
            #expect(process.exit == nil)
        }
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(2))
        #expect(await process.waitForExit() == ContainerExit(status: 0, signaled: false))
    }

    @Test func aProcessThatWasNeverStartedHasNoRunToWaitFor() async throws {
        let runner = try FakeRunner("exit 0")
        defer { runner.remove() }
        let process = make(runner)
        #expect(await process.waitForExit() == .notStarted)
        #expect(process.openDescriptorCount == 0)
    }

    @Test func aLargeOutputIsAppliedWholeWhateverTheReadersWereHeldBack() async throws {
        // 6 MiB on the runner's standard error: more than the backlog lets the readers queue.
        let size = 6 * 1024 * 1024
        let runner = try FakeRunner("yes 0123456789abcdef | head -c \(size) >&2")
        defer { runner.remove() }
        let process = make(runner)
        try process.start()
        #expect(await process.waitForExit() == ContainerExit(status: 0, signaled: false))
        let diagnostics = process.log.diagnostics
        #expect(diagnostics.text.utf8.count + diagnostics.droppedBytes == size)
        #expect(diagnostics.text.utf8.count <= ContainerLog.diagnosticsLimit)
        #expect(process.openDescriptorCount == 0)
    }

    @Test func releasingAProcessKillsItsRunnerAndUnregistersIt() async throws {
        let runner = try FakeRunner("echo $$ > \"$0.pid\"\n" + FakeRunner.waitsForStop)
        defer { runner.remove() }
        let registry = ContainerProcesses()
        let probe = AsyncEventProbe<ContainerEvent>()
        var process: ContainerProcess? = make(runner, registry: registry)
        process?.onEvent = { probe.record($0) }
        try process?.start()
        _ = try await probe.wait(forAtLeast: 1)
        #expect(registry.liveCount == 1)
        let pid = try #require(runner.writtenPid)
        let ended = AsyncEventProbe<Int>()
        let watcher = watchExit(of: pid, into: ended)
        defer { watcher.cancel() }
        process = nil
        #expect(registry.liveCount == 0)
        _ = try await ended.wait(forAtLeast: 1)
    }
}

struct OutputBacklogTests {
    @Test func aReaderIsPausedAboveTheBudgetAndResumedBelowTheLowMark() {
        let backlog = OutputBacklog()
        let reader = CountingReader()
        backlog.queued(OutputBacklog.pauseAbove, from: reader)
        #expect(reader.paused == 0)
        backlog.queued(1, from: reader)
        backlog.queued(1, from: reader)
        #expect(reader.paused == 1)
        backlog.applied(OutputBacklog.pauseAbove + 2 - OutputBacklog.resumeBelow)
        #expect(reader.resumed == 0)
        backlog.applied(1)
        #expect(reader.resumed == 1)
        #expect(backlog.queuedBytes == OutputBacklog.resumeBelow - 1)
        backlog.applied(backlog.queuedBytes)
        #expect(reader.resumed == 1)
    }

    @Test func aClosedBacklogLetsEveryPausedReaderGoAndPausesNone() {
        let backlog = OutputBacklog()
        let first = CountingReader()
        let second = CountingReader()
        backlog.queued(OutputBacklog.pauseAbove + 1, from: first)
        backlog.queued(1, from: second)
        backlog.close()
        #expect(first.resumed == 1 && second.resumed == 1)
        backlog.queued(OutputBacklog.pauseAbove, from: first)
        backlog.applied(OutputBacklog.pauseAbove * 3)
        #expect(first.paused == 1 && second.paused == 1)
        #expect(first.resumed == 1 && second.resumed == 1)
    }
}
