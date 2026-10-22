import Foundation
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// Ending a machine: force stop in every state it can be asked in, quitting, and every way a run can end.
@MainActor
struct MachineStopTests {
    @Test func forceStopStopsARunningOrPausedMachineAndReleasesIt() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        let first = rig.factory.add()
        await rig.start()
        await rig.controller.forceStop()
        #expect(first.count(.stop) == 1)
        rig.expectReleased()

        let second = rig.factory.add()
        await rig.start()
        await rig.controller.pause()
        await rig.controller.forceStop()
        #expect(second.count(.stop) == 1)
        rig.expectReleased()
        try await rig.expectNetworkBalanced(runs: 2)
    }

    @Test func aForceStopTheFrameworkFailsToDoStillReleasesTheMachineAndSaysWhy() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.stop, "stuck")

        await rig.controller.forceStop()
        rig.expectReleased()
        #expect(rig.controller.errorMessage == "stuck")
    }

    @Test func aForceStopDuringAStartWaitsForItThenStopsTheMachineThatCameUp() async throws {
        let rig = try ControllerRig(runtimeMinutes: 60)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        let gate = guest.hold(.start)

        let start = rig.starting()
        try await guest.waitFor(.start)
        await rig.controller.forceStop()
        #expect(rig.controller.state == .stopping)
        #expect(guest.count(.stop) == 0, "the framework cannot stop a machine that is starting")

        gate.open()
        await start.value
        #expect(guest.count(.stop) == 1)
        rig.expectReleased()
        #expect(!rig.config.hasBooted, "a run the user cancelled is not a first boot")
        #expect(rig.controller.errorMessage == nil)
    }

    @Test func aForceStopDuringAStartThatFailsJustEndsIt() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        guest.fail(.start, "cancelled")
        let gate = guest.hold(.start)

        let start = rig.starting()
        try await guest.waitFor(.start)
        await rig.controller.forceStop()
        gate.open()
        await start.value

        rig.expectReleased()
        #expect(guest.count(.stop) == 0)
        #expect(rig.controller.errorMessage == nil, "the user asked for this")
    }

    @Test func aForceStopDuringARestoreThatFailsDoesNotBootTheMachineAnyway() async throws {
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

        #expect(cold.count(.start) == 0)
        rig.expectReleased()
        #expect(rig.bundle.hasSavedState, "the image was not shown to be bad")
    }

    @Test func aRestoreThatFinishesAfterAForceStopIsStoppedAndArmsNothing() async throws {
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

        rig.expectReleased()
        #expect(guest.state == .stopped, "the machine that came up was stopped")
        #expect(guest.count(.stop) == 1)
    }

    @Test func aPauseThatFailsAfterAForceStopRaisesNoAlertAndTheMachineStillStops() async throws {
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

        rig.expectReleased()
        #expect(guest.count(.stop) == 1)
        #expect(rig.controller.errorMessage == nil)
    }

    @Test func aForceStopAskedTwiceGivesUpOnAStopThatHangsAndTheNextRunIsUntouched() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let hung = rig.factory.add("hung")
        let next = rig.factory.add("next")
        await rig.start()
        let gate = hung.hold(.stop)

        let first = Task { await rig.controller.forceStop() }
        try await hung.waitFor(.stop)
        #expect(rig.controller.state == .stopping)
        await rig.controller.forceStop()
        rig.expectReleased()

        await rig.start()
        #expect(rig.controller.state == .running)
        gate.open()
        await first.value
        #expect(rig.controller.state == .running, "the hung stop finishing late belongs to nobody")
        #expect(rig.controller.guest === next)
        #expect(next.count(.stop) == 0)
    }

    @Test func aStartAbandonedByAForceStopCannotTouchTheRunThatReplacedIt() async throws {
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
        await rig.controller.forceStop()
        rig.expectReleased()

        let secondStart = rig.starting()
        try await second.waitFor(.start)
        firstGate.open()
        await firstStart.value
        #expect(rig.controller.state == .starting(.booting), "the first start's failure was not the second run's")
        #expect(rig.controller.errorMessage == nil)

        secondGate.open()
        await secondStart.value
        #expect(rig.controller.state == .running)
        #expect(rig.controller.guest === second)
    }

    @Test func aStartAbandonedByAForceStopThatSucceedsLateIsStopped() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let first = rig.factory.add("first")
        let second = rig.factory.add("second")
        let firstGate = first.hold(.start)

        let firstStart = rig.starting()
        try await first.waitFor(.start)
        await rig.controller.forceStop()
        await rig.controller.forceStop()
        await rig.start()
        #expect(rig.controller.guest === second)

        firstGate.open()
        await firstStart.value
        #expect(first.state == .stopped, "the machine that came up after it was abandoned does not keep running")
        #expect(rig.controller.state == .running)
        #expect(rig.controller.guest === second)
    }

    @Test func quittingMidSuspendRemovesThePartialImageAndReleasesEverything() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let gate = guest.hold(.save)

        let suspending = Task { await rig.controller.suspend() }
        try await guest.waitFor(.save)
        rig.controller.quit()
        rig.expectReleased()
        #expect(!rig.bundle.hasSavedState)

        gate.open()
        await suspending.value
        #expect(!rig.bundle.hasSavedState, "an image finished after the machine was let go is not left behind")
    }

    @Test func quittingARunningDisposableMachineDiscardsItsCopyAndStopsItsStack() async throws {
        let rig = try ControllerRig(ephemeral: true, runtimeMinutes: 60)
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()
        #expect(rig.disposableCopyExists)

        rig.controller.quit()
        rig.expectReleased()
        try await rig.expectNetworkBalanced(runs: 1)
    }

    @Test func quittingAStoppedMachineChangesNothing() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.controller.quit()
        rig.expectReleased()
    }

    enum Ending: CaseIterable, CustomTestStringConvertible, Sendable {
        case guestPowersOff, guestCrashes, forceStop, forceStopWhilePaused, startFails, suspended, quit, forceStoppedTwiceWhileStarting

        var testDescription: String { String(describing: self) }
        /// Suspending is off for a disposable machine.
        var isDisposable: Bool { self != .suspended }
    }

    @Test(arguments: Ending.allCases)
    func everyEndingReleasesEverythingAndLeavesTheMachineStartableAgain(_ ending: Ending) async throws {
        let rig = try ControllerRig(ephemeral: ending.isDisposable, runtimeMinutes: 60)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        var runs = 1
        switch ending {
        case .guestPowersOff:
            await rig.start()
            guest.powerOff()
        case .guestCrashes:
            await rig.start()
            guest.crash("boom")
        case .forceStop:
            await rig.start()
            await rig.controller.forceStop()
        case .forceStopWhilePaused:
            await rig.start()
            await rig.controller.pause()
            await rig.controller.forceStop()
        case .startFails:
            guest.fail(.start, "boom")
            await rig.start()
        case .suspended:
            await rig.start()
            await rig.controller.suspend()
        case .quit:
            await rig.start()
            rig.controller.quit()
        case .forceStoppedTwiceWhileStarting:
            let gate = guest.hold(.start)
            let start = rig.starting()
            try await guest.waitFor(.start)
            await rig.controller.forceStop()
            await rig.controller.forceStop()
            gate.open()
            await start.value
        }
        rig.expectReleased()
        try await rig.expectNetworkBalanced(runs: runs)

        let again = rig.factory.add("again")
        await rig.start()
        runs += 1
        #expect(rig.controller.state == .running)
        #expect(rig.controller.guest === again)
        again.powerOff()
        rig.expectReleased()
        try await rig.expectNetworkBalanced(runs: runs)
    }
}
