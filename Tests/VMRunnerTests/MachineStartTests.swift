import Foundation
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// Starting a machine: a cold boot, a restore and its fallback, the runtime limit, and what the library sees.
@MainActor
struct MachineStartTests {
    @Test func aColdStartRunsTheMachineAndEndsWhenTheGuestPowersOff() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()

        await rig.start()
        #expect(rig.controller.state == .running)
        #expect(guest.count(.start) == 1)
        #expect(rig.controller.network != nil)
        #expect(rig.controller.virtualMachine == nil, "a fake has no framework machine to show")
        #expect(rig.config.hasBooted, "the first boot is recorded")
        #expect(rig.activity.isHeld, "macOS is told the app is latency-critical while a machine exists")

        guest.powerOff()
        rig.expectReleased()
        try await rig.expectNetworkBalanced(runs: 1)
    }

    @Test func aMachineThatStopsWithAnErrorIsReleasedAndSaysSo() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.disposableCopyExists)

        guest.crash("the GPU hung")
        rig.expectReleased()
        #expect(rig.controller.errorMessage == "The virtual machine stopped: the GPU hung")
        try await rig.expectNetworkBalanced(runs: 1)
    }

    @Test func aStartThatFailsAfterTheStackBeganReleasesEverything() async throws {
        let rig = try ControllerRig(ephemeral: true, runtimeMinutes: 60)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        guest.fail(.start, "boom")

        await rig.start()
        rig.expectReleased()
        #expect(rig.controller.errorMessage == "boom")
        #expect(!rig.config.hasBooted)
        try await rig.expectNetworkBalanced(runs: 1)
    }

    @Test func aConfigurationThatFailsToBuildDiscardsTheDisposableCopy() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        rig.factory.failure = "invalid configuration"

        await rig.start()
        rig.expectReleased()
        #expect(rig.controller.errorMessage == "invalid configuration")
    }

    @Test func startingAMachineThatIsAlreadyStartingOrRunningDoesNothing() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        let gate = guest.hold(.start)

        let first = rig.starting()
        try await guest.waitFor(.start)
        await rig.start()
        #expect(rig.factory.preparations == 1)
        #expect(rig.controller.state == .starting(.booting))

        gate.open()
        await first.value
        await rig.start()
        #expect(rig.factory.preparations == 1)
        #expect(rig.controller.state == .running)
        #expect(rig.controller.errorMessage == nil, "a second click is not an error")
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
        #expect(rig.controller.state == .running)
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
        #expect(rig.controller.state == .running)
        #expect(rig.controller.errorMessage?.contains("Booted normally instead") == true)
        #expect(!rig.bundle.hasSavedState)
        let events = try await rig.factory.network.wait(forAtLeast: 3).sorted()
        #expect(events == ["begin#1", "begin#2", "shutdown#1"], "each attempt has its own stack, and the failed one is stopped")
    }

    @Test func aColdBootAfterAFailedRestoreStartsOnTheColdStartSizeNotTheRememberedOne() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add("restoring").fail(.restore, "the image doesn't match")
        let cold = rig.factory.add("cold")
        rig.remember(width: 3456, height: 2234)
        try rig.leaveSavedState()
        let window = CGSize(width: 1512, height: 900)
        let expected = StartDisplay.size(for: rig.config, window: window, restoring: false)

        await rig.start(window: window)
        #expect(cold.count(.start) == 1)
        #expect(rig.factory.displays == [.init(width: 3456, height: 2234), .init(width: expected.width, height: expected.height)])
        #expect(expected.width == 1280, "the firmware gets the capped size")
        #expect(rig.config.lastDisplayWidth == expected.width && rig.config.lastDisplayHeight == expected.height)
    }

    @Test func aMachineThatCannotRestoreItsStateColdBootsOnTheColdStartSize() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.suspend = .unavailable(reason: "this configuration can't be saved")
        let unused = rig.factory.add("built for the remembered size")
        let cold = rig.factory.add("cold")
        rig.remember(width: 3456, height: 2234)
        try rig.leaveSavedState()
        let window = CGSize(width: 1512, height: 900)
        let expected = StartDisplay.size(for: rig.config, window: window, restoring: false)

        await rig.start(window: window)
        #expect(unused.count(.start) == 0 && cold.count(.start) == 1)
        #expect(rig.factory.displays == [.init(width: 3456, height: 2234), .init(width: expected.width, height: expected.height)])
        #expect(rig.controller.state == .running)
    }

    @Test func aRestoreThatWorksKeepsTheRememberedSizeAndPreparesOnce() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        rig.remember(width: 3456, height: 2234)
        try rig.leaveSavedState()

        await rig.start(window: CGSize(width: 1512, height: 900))
        #expect(guest.count(.restore) == 1)
        #expect(rig.factory.displays == [.init(width: 3456, height: 2234)], "saved state restores only at the size it was taken on")
    }

    @Test func aColdBootDoesNotLeaveAMemoryImageThatNoLongerMatchesTheDisk() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.suspend = .unavailable(reason: "this configuration can't be saved")
        let guest = rig.factory.add()
        try rig.leaveSavedState()

        await rig.start()
        #expect(guest.count(.start) == 1, "the image can't be used, so the machine boots cold")
        #expect(!rig.bundle.hasSavedState, "and the disk is about to change under it")
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
        #expect(rig.controller.state == .shuttingDown)
        try await rig.clock.waitForSleepers(atLeast: 1)
        #expect(guest.count(.stop) == 0, "the guest gets its grace period")

        rig.clock.advance(by: RuntimeLimit.gracePeriod)
        _ = try await rig.factory.network.wait(forAtLeast: 2)
        #expect(guest.count(.stop) == 1)
        rig.expectReleased()
    }

    @Test func aPausedGuestCannotAnswerSoTheLimitWaitsForTheGracePeriodAndForcesIt() async throws {
        let rig = try ControllerRig(runtimeMinutes: 60)
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        await rig.controller.pause()

        try await rig.clock.waitForSleepers(atLeast: 1)
        rig.clock.advance(by: .seconds(60 * 60))
        try await rig.clock.waitForSleepers(atLeast: 1)
        #expect(guest.count(.requestStop) == 0)
        #expect(rig.controller.errorMessage == nil, "a timer is not the user, and a refusal is not for it")

        rig.clock.advance(by: RuntimeLimit.gracePeriod)
        _ = try await rig.factory.network.wait(forAtLeast: 2)
        rig.expectReleased()
        #expect(guest.count(.stop) == 1)
    }

    @Test func theLimitOfOneRunNeverReachesTheNext() async throws {
        let rig = try ControllerRig(runtimeMinutes: 60)
        defer { rig.cleanUp() }
        let first = rig.factory.add("first")
        let second = rig.factory.add("second")
        await rig.start()
        try await rig.clock.waitForSleepers(atLeast: 1)
        first.powerOff()
        #expect(rig.clock.sleeperCount == 0, "released with the run")

        await rig.start()
        try await rig.clock.waitForSleepers(atLeast: 1)
        rig.clock.advance(by: .seconds(60 * 60))
        try await second.waitFor(.requestStop)
        #expect(first.count(.requestStop) == 0)
        #expect(second.count(.requestStop) == 1)
    }

    @Test func aPolicyEditedWhileTheMachineRunsReachesItsNetwork() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()
        let activity = try #require(rig.controller.network)
        #expect(activity.isRunning)

        var config = rig.config
        config.name = "renamed"
        rig.library.update(config)
        #expect(activity.policy == NetworkPolicy(), "an unrelated edit is not a policy change")

        try config.networkPolicy.add("evil.com", to: .blockedDomains)
        rig.library.update(config)
        #expect(activity.policy.rules(in: .blockedDomains) == ["evil.com"])
    }

    @Test func aMachineWithNoStackHasNoActivityAndIgnoresPolicyEdits() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.withNetwork = false
        rig.factory.add()
        await rig.start()

        var config = rig.config
        try config.networkPolicy.add("22", to: .blockedPorts)
        rig.library.update(config)
        #expect(rig.controller.network == nil)
    }

    @Test func aFreshStartGetsItsOwnStackAndTheEarlierOneStaysStopped() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let first = rig.factory.add()
        rig.factory.add()
        await rig.start()
        let firstActivity = try #require(rig.controller.network)
        first.powerOff()
        #expect(!firstActivity.isRunning)

        await rig.start()
        #expect(rig.controller.network !== firstActivity)
        #expect(rig.controller.network?.isRunning == true)
    }
}
