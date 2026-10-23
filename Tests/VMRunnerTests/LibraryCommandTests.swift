import Foundation
import TestKit
import Testing

@testable import VMRunner

/// Starting and suspending through the library and waiting for the result, with fake machines in a scratch folder.
@MainActor
struct LibraryCommandTests {
    @Test
    func aStartReturnsOnceTheMachineRuns() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        #expect(await rig.library.startAndWait(rig.id) == .done(.running))
        #expect(rig.controller.state == .running)
    }

    @Test
    func aSecondStartIsRefusedAndSaysWhatTheMachineIsDoing() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        _ = await rig.library.startAndWait(rig.id)
        #expect(await rig.library.startAndWait(rig.id) == .refused("“fake” is already running."))
    }

    @Test
    func aStartThatFailsSaysSoAndLeavesTheMachineStopped() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.failure = "no disk"
        let result = await rig.library.startAndWait(rig.id)
        guard case .failed(let message) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(message.contains("no disk"))
        #expect(rig.controller.state == .stopped)
    }

    @Test
    func anUnknownMachineOrOneThatIsNotSetUpIsRefused() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        #expect(await rig.library.startAndWait(UUID()) == .refused("There is no such machine."))
        var config = rig.config
        config.isProvisioned = false
        rig.library.update(config)
        #expect(await rig.library.startAndWait(rig.id) == .refused("“fake” is not set up yet."))
        #expect(rig.factory.preparations == 0, "nothing was prepared")
    }

    @Test
    func hostPathsTheUserHasNotApprovedRefuseTheStartWithoutAsking() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        var config = rig.config
        config.sharedFolders = [SharedFolder(path: "/tmp/never-approved-\(UUID().uuidString)")]
        rig.library.update(config)
        let result = await rig.library.startAndWait(rig.id)
        #expect(result == .refused("“fake” uses host paths you have not approved in VMRunner. Start it once from the app."))
        #expect(rig.library.pendingApproval == nil, "nobody is asked")
        #expect(rig.factory.preparations == 0)
    }

    @Test
    func aMachineInSetupIsRefused() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AsyncGate()
        let library = VMLibrary(machinesDirectory: directory, provision: { _, _, _ in try await gate.waitUntilOpen() })
        var config = VMConfig.new(name: "installing", guest: .linux)
        config.isProvisioned = true
        try library.add(config)
        library.beginSetup(config.id)
        let job = try #require(library.jobs[config.id])

        #expect(await library.startAndWait(config.id) == .refused("“installing” is being set up."))

        library.cancelJob(config.id)
        gate.open()
        await job.task?.value
    }

    @Test
    func aSuspendReturnsOnceTheMachineHasStoppedWithItsImageSaved() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        _ = await rig.library.startAndWait(rig.id)
        #expect(await rig.library.suspendAndWait(rig.id) == .done(.stopped))
        #expect(rig.bundle.hasSavedState)
    }

    @Test
    func aSuspendTheMachineCannotDoIsAFailureWithItsReason() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.suspend = .unavailable(reason: "Filtered networking can't be saved.")
        rig.factory.add()
        _ = await rig.library.startAndWait(rig.id)
        #expect(await rig.library.suspendAndWait(rig.id) == .failed("Filtered networking can't be saved."))
        #expect(rig.controller.state == .running)
        await rig.controller.forceStop()
    }

    @Test
    func suspendingAStoppedMachineIsRefused() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        #expect(await rig.library.suspendAndWait(rig.id) == .refused("“fake” is not running."))
    }

    @Test
    func aCleanStopOfAMachineThatIsStartingIsRefusedWithItsState() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let gate = rig.factory.holdPreparation()
        rig.factory.add()
        let starting = rig.starting()
        _ = try await rig.factory.held.wait(forAtLeast: 1)
        let activity = rig.controller.state.activity
        #expect(
            await rig.library.stopAndWait(rig.id, force: false) == .refused("“fake” is \(activity); a clean stop needs it running."))
        gate.open()
        await starting.value
        await rig.controller.forceStop()
    }

    @Test
    func aCleanStopOfAPausedMachineIsRefusedWithItsState() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        _ = await rig.library.startAndWait(rig.id)
        await rig.controller.pause()
        #expect(rig.controller.state == .paused)
        let activity = rig.controller.state.activity
        #expect(
            await rig.library.stopAndWait(rig.id, force: false) == .refused("“fake” is \(activity); a clean stop needs it running."))
        await rig.controller.forceStop()
    }

    @Test
    func theMenuPathsStillStartAndSuspend() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        rig.library.startMachine(rig.id, interactive: false)
        try await guest.waitFor(.start)
        rig.library.suspendMachine(rig.id)
        try await guest.waitFor(.save)
        // Let the suspend finish before the scratch folder goes.
        await poll(every: .milliseconds(10), attempts: 500, clock: ContinuousClock()) { rig.controller.state == .stopped }
        #expect(rig.controller.state == .stopped)
    }
}
