import Foundation
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// The controller driven through fakes: no virtual machine, no sockets. Each test that says "known issue" pins a defect
/// the next commit fixes.
@MainActor
struct MachineControllerTests {
    private func settledNetwork(_ rig: ControllerRig, count: Int) async throws -> [String] {
        try await rig.factory.network.wait(forAtLeast: count).sorted()
    }

    // MARK: Behaviour that stays

    @Test func aColdStartRunsTheMachineAndTheStackIsStoppedWhenTheGuestPowersOff() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()

        await rig.start()
        #expect(rig.controller.isActive)
        #expect(guest.count(.start) == 1)
        #expect(rig.controller.network != nil)

        guest.powerOff()
        #expect(!rig.controller.isActive)
        #expect(rig.controller.network == nil)
        #expect(try await settledNetwork(rig, count: 2) == ["begin#1", "shutdown#1"])
    }

    @Test func aMachineThatStopsWithAnErrorIsReleasedAndSaysSo() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.disposableCopyExists)

        guest.crash("the GPU hung")
        #expect(!rig.controller.isActive)
        #expect(rig.controller.errorMessage == "The virtual machine stopped: the GPU hung")
        #expect(rig.controller.network == nil)
        #expect(!rig.disposableCopyExists)
    }

    @Test func aStartThatFailsAfterTheStackBeganReleasesEverything() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        guest.fail(.start, "boom")

        await rig.start()
        #expect(!rig.controller.isActive)
        #expect(rig.controller.errorMessage == "boom")
        #expect(rig.controller.network == nil)
        #expect(!rig.disposableCopyExists, "the disposable copy was made before the failure")
        #expect(try await settledNetwork(rig, count: 2) == ["begin#1", "shutdown#1"])
    }

    @Test func aConfigurationThatFailsToBuildDiscardsTheDisposableCopy() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        rig.factory.failure = "invalid configuration"

        await rig.start()
        #expect(!rig.controller.isActive)
        #expect(rig.controller.errorMessage == "invalid configuration")
        #expect(!rig.disposableCopyExists)
    }

    @Test func aSavedStateIsRestoredAndThenDiscarded() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        try rig.leaveSavedState()

        await rig.start()
        #expect(guest.count(.restore) == 1)
        #expect(guest.count(.resume) == 1)
        #expect(guest.count(.start) == 0)
        #expect(rig.controller.isActive)
        #expect(!rig.bundle.hasSavedState, "the image goes once it is loaded: the disk is about to change")
    }

    @Test func aRestoreThatFailsFallsBackToAColdBootWithANotice() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let failing = rig.factory.add("restoring")
        let cold = rig.factory.add("cold")
        failing.fail(.restore, "the image doesn't match")
        try rig.leaveSavedState()

        await rig.start()
        #expect(cold.count(.start) == 1)
        #expect(rig.controller.isActive)
        #expect(rig.controller.errorMessage?.contains("Booted normally instead") == true)
        #expect(!rig.bundle.hasSavedState)
        #expect(try await settledNetwork(rig, count: 3) == ["begin#1", "begin#2", "shutdown#1"])
    }

    @Test func theRuntimeLimitAsksThenForcesAfterTheGracePeriod() async throws {
        let rig = try ControllerRig(runtimeMinutes: 60)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.controller.deadline != nil)

        try await rig.clock.waitForSleepers(atLeast: 1)
        rig.clock.advance(by: .seconds(60 * 60))
        try await guest.waitFor(.requestStop)
        try await rig.clock.waitForSleepers(atLeast: 1)
        #expect(guest.count(.stop) == 0, "the guest gets its grace period")

        rig.clock.advance(by: RuntimeLimit.gracePeriod)
        try await guest.waitFor(.stop)
        #expect(await settles { !rig.controller.isActive })
        #expect(rig.controller.deadline == nil)
    }

    // MARK: Defects the transition rules fix

    @Test func theUIMirrorDoesNotDependOnTheFrameworkAnnouncingItsStates() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        guest.announcesStateChanges = false

        await rig.start()
        await rig.controller.pause()
        withKnownIssue("the state is only copied from the framework's announcements") {
            #expect(rig.controller.state == .paused)
        }
    }

    @Test func pausingAMachineThatIsAlreadyPausedSaysSoInPlainWords() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()
        await rig.controller.pause()
        await rig.controller.pause()

        withKnownIssue("the framework's own error text reaches the alert") {
            #expect(rig.controller.errorMessage == "The machine is already paused.")
        }
    }

    @Test func aStartThatFailsLateDoesNotTearDownTheRunThatReplacedIt() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let first = rig.factory.add("first")
        let second = rig.factory.add("second")
        first.fail(.start, "late failure")
        let firstGate = first.hold(.start)
        let secondGate = second.hold(.start)

        let firstStart = rig.starting()
        try await first.waitFor(.start)
        await rig.controller.forceStop()
        #expect(!rig.controller.isActive)

        let secondStart = rig.starting()
        try await second.waitFor(.start)
        firstGate.open()
        await firstStart.value
        withKnownIssue("the first start's catch releases whatever run is current") {
            #expect(rig.controller.isActive, "the second run was torn down by the first run's failure")
        }

        secondGate.open()
        await secondStart.value
    }

    @Test func aForceStopDuringARestoreDoesNotBootTheMachineAnyway() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let restoring = rig.factory.add("restoring")
        let cold = rig.factory.add("cold")
        try rig.leaveSavedState()
        restoring.fail(.restore, "interrupted")
        let gate = restoring.hold(.restore)

        let start = rig.starting()
        try await restoring.waitFor(.restore)
        await rig.controller.forceStop()
        gate.open()
        await start.value

        withKnownIssue("a failed restore always falls back to a cold boot") {
            #expect(cold.count(.start) == 0)
            #expect(!rig.controller.isActive)
        }
    }

    @Test func aRestoreThatFinishesAfterAForceStopArmsNothingAndLeavesNothingRunning() async throws {
        let rig = try ControllerRig(runtimeMinutes: 60)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        try rig.leaveSavedState()
        let gate = guest.hold(.restore)

        let start = rig.starting()
        try await guest.waitFor(.restore)
        await rig.controller.forceStop()
        gate.open()
        await start.value

        withKnownIssue("the limit is armed for a machine that was already released") {
            #expect(rig.controller.deadline == nil)
        }
        withKnownIssue("nobody stops the machine that came up after the release") {
            #expect(guest.state != .running)
        }
    }

    @Test func aFailurePausingAMachineThatWasForceStoppedRaisesNoAlert() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.pause, "the framework gave up")
        let gate = guest.hold(.pause)

        let pausing = Task { await rig.controller.pause() }
        try await guest.waitFor(.pause)
        await rig.controller.forceStop()
        gate.open()
        await pausing.value

        withKnownIssue("the late failure is reported against a machine that is gone") {
            #expect(rig.controller.errorMessage == nil)
        }
    }

    @Test func suspendingTwiceKeepsTheImageTheFirstSuspendWrote() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let stopGate = guest.hold(.stop)

        let first = Task { await rig.controller.suspend(to: rig.bundle) }
        try await guest.waitFor(.stop)
        #expect(rig.bundle.hasSavedState, "written, and the machine is about to stop")
        await rig.controller.suspend(to: rig.bundle)
        stopGate.open()
        await first.value

        #expect(!rig.controller.isActive)
        withKnownIssue("the second suspend failed and removed the first one's image") {
            #expect(rig.bundle.hasSavedState)
            #expect(rig.controller.errorMessage == nil)
        }
    }

    @Test func suspendingWhileARestoreIsRunningLeavesTheImageAlone() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        try rig.leaveSavedState()
        let gate = guest.hold(.restore)

        let start = rig.starting()
        try await guest.waitFor(.restore)
        await rig.controller.suspend(to: rig.bundle)
        withKnownIssue("Suspend is offered during the start, fails, and deletes the image being restored") {
            #expect(rig.bundle.hasSavedState)
        }

        gate.open()
        await start.value
    }

    @Test func aColdBootDoesNotLeaveAMemoryImageThatNoLongerMatchesTheDisk() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.suspend = .unavailable(reason: "this configuration can't be saved")
        let guest = rig.factory.add()
        try rig.leaveSavedState()

        await rig.start()
        #expect(guest.count(.start) == 1, "the image can't be used, so the machine boots cold")
        withKnownIssue("the image stays on disk while the disk changes under it") {
            #expect(!rig.bundle.hasSavedState)
        }
    }

    @Test func afterTheMachineStopsSuspendIsNoLongerOffered() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.controller.canSuspend)

        guest.powerOff()
        withKnownIssue("the run's suspend support outlives the run") {
            #expect(!rig.controller.canSuspend)
        }
    }

    /// Lets queued main-actor work run, a bounded number of times, until `condition` holds.
    private func settles(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        return condition()
    }
}
