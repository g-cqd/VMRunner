import Foundation
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// Suspending a machine to disk, and the ways that can go wrong.
@MainActor
struct MachineSuspendTests {
    @Test func suspendingSavesTheImagePrivatelyStopsTheMachineAndReleasesIt() async throws {
        let rig = try ControllerRig(ephemeral: false)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.controller.canSuspend)

        await rig.controller.suspend()
        rig.expectReleased()
        #expect(guest.count(.pause) == 1 && guest.count(.save) == 1 && guest.count(.stop) == 1)
        #expect(rig.bundle.hasSavedState)
        let permissions = try FileManager.default.attributesOfItem(atPath: rig.bundle.savedState.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "the guest's memory is in it")
        try await rig.expectNetworkBalanced(runs: 1)

        let again = rig.factory.add("again")
        await rig.start()
        #expect(again.count(.restore) == 1, "the next start restores it")
    }

    @Test func aMachineThatCannotBeSavedExplainsWhyAndKeepsRunning() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.suspend = .unavailable(reason: "Filtered networking can't be saved.")
        let guest = rig.factory.add()
        await rig.start()
        #expect(!rig.controller.canSuspend)
        #expect(rig.controller.suspendUnavailableReason == "Filtered networking can't be saved.")

        await rig.controller.suspend()
        #expect(rig.controller.errorMessage == "Filtered networking can't be saved.")
        #expect(rig.controller.state == .running)
        #expect(guest.count(.pause) == 0)
    }

    @Test func suspendingAPausedMachineDoesNotPauseItAgain() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        await rig.controller.pause()

        await rig.controller.suspend()
        rig.expectReleased()
        #expect(guest.count(.pause) == 1)
        #expect(rig.bundle.hasSavedState)
    }

    @Test func suspendingTwiceKeepsTheImageTheFirstSuspendWrote() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let stopGate = guest.hold(.stop)

        let first = Task { await rig.controller.suspend() }
        try await guest.waitFor(.stop)
        #expect(rig.bundle.hasSavedState, "written, and the machine is about to stop")
        await rig.controller.suspend()
        stopGate.open()
        await first.value

        rig.expectReleased()
        #expect(rig.bundle.hasSavedState)
        #expect(rig.controller.errorMessage == nil, "a second click is not an error")
        #expect(guest.count(.save) == 1)
    }

    @Test func suspendingWhileARestoreIsRunningIsRefusedAndLeavesTheImageAlone() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        try rig.leaveSavedState()
        let gate = guest.hold(.restore)

        let start = rig.starting()
        try await guest.waitFor(.restore)
        await rig.controller.suspend()
        #expect(rig.bundle.hasSavedState)
        #expect(rig.controller.errorMessage?.contains("resuming from suspended state") == true)
        #expect(guest.count(.save) == 0)

        gate.open()
        await start.value
        #expect(rig.controller.state == .running)
    }

    @Test func aSuspendThatFailsToSaveRemovesTheImageAndLeavesThePausedMachineToResume() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.save, "the disk is full")

        await rig.controller.suspend()
        #expect(rig.controller.state == .paused)
        #expect(rig.controller.errorMessage == "Couldn't suspend: the disk is full")
        #expect(!rig.bundle.hasSavedState, "a partial image next to a disk that keeps changing is worse than none")

        await rig.controller.resume()
        #expect(rig.controller.state == .running)
    }

    @Test func aSuspendThatFailsToPauseLeavesTheMachineRunning() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.pause, "busy")

        await rig.controller.suspend()
        #expect(rig.controller.state == .running)
        #expect(rig.controller.errorMessage == "Couldn't suspend: busy")
        #expect(!rig.bundle.hasSavedState)
    }

    @Test func aSuspendWhoseStopFailsRemovesTheImageSoItIsNeverRestoredAgainstAChangingDisk() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.stop, "stuck")

        await rig.controller.suspend()
        #expect(rig.controller.state == .paused)
        #expect(!rig.bundle.hasSavedState)
        await rig.controller.forceStop()
        rig.expectReleased()
    }

    @Test func aGuestThatIgnoresAShutdownRequestCanStillBeSuspended() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()
        rig.controller.requestStop()
        #expect(rig.controller.state == .shuttingDown)

        await rig.controller.suspend()
        rig.expectReleased()
        #expect(rig.bundle.hasSavedState)
    }

    @Test func suspendIsNotOfferedOnceTheMachineStops() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.controller.canSuspend)

        guest.powerOff()
        #expect(!rig.controller.canSuspend)
    }
}
