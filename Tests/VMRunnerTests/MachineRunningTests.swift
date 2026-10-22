import Foundation
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// A running machine: pausing, resuming, asking the guest to shut down, and reports that arrive late.
@MainActor
struct MachineRunningTests {
    @Test func pausingAndResumingShowEachStepWithoutHelpFromTheFramework() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let model = rig.library.model(for: rig.id)
        #expect(model.state.canPause && !model.state.showsResume)
        let pauseGate = guest.hold(.pause)

        let pausing = Task { await rig.controller.pause() }
        try await guest.waitFor(.pause)
        #expect(rig.controller.state == .pausing)
        #expect(model.state.statusText == "Pausing…")
        #expect(!model.state.canPause && !model.state.canResume, "nothing to click while it pauses")
        pauseGate.open()
        await pausing.value
        #expect(rig.controller.state == .paused)
        #expect(model.state.showsResume && model.state.canResume && !model.state.canPause, "a paused machine offers Resume")
        #expect(!model.state.canShutDown, "and a frozen guest cannot be asked to shut down")
        #expect(model.isRunning)

        let resumeGate = guest.hold(.resume)
        let resuming = Task { await rig.controller.resume() }
        try await guest.waitFor(.resume)
        #expect(rig.controller.state == .resuming)
        resumeGate.open()
        await resuming.value
        #expect(rig.controller.state == .running)
    }

    @Test func pausingAMachineThatIsAlreadyPausedSaysSoInPlainWordsAndAsksTheFrameworkNothing() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        await rig.controller.pause()
        #expect(rig.controller.errorMessage == nil)

        await rig.controller.pause()
        #expect(rig.controller.errorMessage == "The machine is already paused.")
        #expect(guest.count(.pause) == 1)
        #expect(rig.controller.state == .paused)
    }

    @Test func resumingAMachineThatIsNotPausedSaysSo() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()

        await rig.controller.resume()
        #expect(rig.controller.errorMessage == "The machine isn't paused.")
        #expect(guest.count(.resume) == 0)
    }

    @Test func aPauseThatFailsLeavesTheMachineRunningAndSaysWhy() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.pause, "the framework gave up")

        await rig.controller.pause()
        #expect(rig.controller.state == .running)
        #expect(rig.controller.errorMessage == "the framework gave up")
    }

    @Test func repeatedClicksWhileAStepIsInFlightAreOneStep() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let gate = guest.hold(.pause)

        let clicks = (0..<3).map { _ in Task { await rig.controller.pause() } }
        try await guest.waitFor(.pause)
        gate.open()
        for click in clicks { await click.value }

        #expect(guest.count(.pause) == 1)
        #expect(rig.controller.state == .paused)
        #expect(rig.controller.errorMessage == nil)
    }

    @Test func shuttingDownShowsAPendingStateAndAGuestThatIgnoresItCanStillBePausedOrStopped() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()

        rig.controller.requestStop()
        #expect(rig.controller.state == .shuttingDown)
        #expect(guest.count(.requestStop) == 1)

        await rig.controller.pause()
        #expect(rig.controller.state == .paused, "the guest did not answer, so the user is not stuck")
        await rig.controller.resume()
        rig.controller.requestStop()
        #expect(guest.count(.requestStop) == 2, "asking again is allowed")

        guest.powerOff()
        rig.expectReleased()
    }

    @Test func aPausedMachineCannotBeAskedToShutDownAndSaysWhatToDo() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        await rig.controller.pause()

        rig.controller.requestStop()
        #expect(guest.count(.requestStop) == 0, "the framework is not asked to do what it would refuse")
        #expect(rig.controller.errorMessage?.contains("Resume it first") == true)
        #expect(rig.controller.state == .paused)
    }

    @Test func aShutdownRequestTheFrameworkRefusesIsReportedAndTheMachineKeepsRunning() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.requestStop, "the guest has no power button")

        rig.controller.requestStop()
        #expect(rig.controller.state == .running)
        #expect(rig.controller.errorMessage == "the guest has no power button")
    }

    @Test func aStopReportFromAnEarlierRunIsIgnoredByTheNextOne() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let first = rig.factory.add("first")
        let second = rig.factory.add("second")
        await rig.start()
        let lateStop = try #require(first.onGuestStopped)
        first.powerOff()
        await rig.start()
        #expect(rig.controller.guest === second)

        lateStop()
        #expect(rig.controller.state == .running)
        #expect(rig.controller.guest === second)
    }

    @Test func anErrorReportThatArrivesAfterASuspendIsIgnored() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let lateError = try #require(guest.onStoppedWithError)
        await rig.controller.suspend()
        rig.expectReleased()

        lateError("the machine stopped after saving")
        #expect(rig.controller.errorMessage == nil)
        #expect(rig.bundle.hasSavedState)
    }

    @Test func aGuestThatPowersOffWhileAForceStopIsInFlightEndsTheRunOnce() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let gate = guest.hold(.stop)

        let stopping = Task { await rig.controller.forceStop() }
        try await guest.waitFor(.stop)
        guest.powerOff()
        rig.expectReleased()
        gate.open()
        await stopping.value
        rig.expectReleased()
        #expect(rig.controller.errorMessage == nil)
    }

    @Test func anErrorFromAMachineTheUserForceStoppedIsNotReported() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let gate = guest.hold(.stop)

        let stopping = Task { await rig.controller.forceStop() }
        try await guest.waitFor(.stop)
        guest.crash("the plug was pulled")
        rig.expectReleased()
        #expect(rig.controller.errorMessage == nil)
        gate.open()
        await stopping.value
    }

    @Test func aGuestThatPowersOffWhileAPauseIsInFlightEndsTheRun() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.pause, "the machine is gone")
        let gate = guest.hold(.pause)

        let pausing = Task { await rig.controller.pause() }
        try await guest.waitFor(.pause)
        guest.powerOff()
        gate.open()
        await pausing.value
        rig.expectReleased()
        #expect(rig.controller.errorMessage == nil)
    }
}
