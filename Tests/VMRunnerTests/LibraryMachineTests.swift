import Foundation
import TestKit
import Testing

@testable import VMRunner

/// Setup work that does not stop when asked to, as an installer that takes a while to unwind does: it finishes when the
/// test says so, then reports the cancellation if it was cancelled.
@MainActor
private final class StubbornSetup {
    let events = AsyncEventProbe<String>()
    private(set) var active = 0
    private(set) var mostAtOnce = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// When set, the work fails with this instead of finishing.
    var failure: String?

    func run() async throws {
        active += 1
        mostAtOnce = max(mostAtOnce, active)
        events.record("started")
        await withCheckedContinuation { waiting.append($0) }
        active -= 1
        try Task.checkCancellation()
        if let failure { throw FakeGuestError(message: failure) }
    }

    func finishAll() {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
struct LibraryMachineTests {
    private func makeLibrary(in directory: URL, running work: StubbornSetup) -> VMLibrary {
        VMLibrary(machinesDirectory: directory, provision: { _, _, _ in try await work.run() })
    }

    @Test func resumingASetupRightAfterCancellingWaitsForTheCancelledRunToUnwind() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = StubbornSetup()
        let library = makeLibrary(in: directory, running: work)
        let config = VMConfig.new(name: "unfinished", guest: .linux)
        try library.add(config)

        library.beginSetup(config.id)
        let first = try #require(library.jobs[config.id])
        _ = try await work.events.wait(forAtLeast: 1)

        library.cancelJob(config.id)
        #expect(library.jobs[config.id] === first, "it is still unwinding, so it stays where the screen can see it")
        library.beginSetup(config.id)
        for _ in 0..<20 { await Task.yield() }
        #expect(work.mostAtOnce == 1, "a second run on the same bundle would write the same disk")
        #expect(library.jobs[config.id] === first)

        work.finishAll()
        await first.task?.value
        #expect(library.jobs[config.id] == nil)
        #expect(first.isFinished)

        library.beginSetup(config.id)
        _ = try await work.events.wait(forAtLeast: 2)
        let second = try #require(library.jobs[config.id])
        #expect(second !== first)
        work.finishAll()
        await second.task?.value
        #expect(library.jobs[config.id] == nil)
    }

    @Test func aFailedSetupStaysOnScreenUntilItIsDismissedAndThenCanBeRetried() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = StubbornSetup()
        work.failure = "the download was cut"
        let library = makeLibrary(in: directory, running: work)
        let config = VMConfig.new(name: "unfinished", guest: .linux)
        try library.add(config)

        library.beginSetup(config.id)
        let failed = try #require(library.jobs[config.id])
        _ = try await work.events.wait(forAtLeast: 1)
        work.finishAll()
        await failed.task?.value
        #expect(library.jobs[config.id] === failed)
        #expect(failed.error == "the download was cut")
        #expect(failed.isFinished)

        library.beginSetup(config.id)
        #expect(library.jobs[config.id] === failed, "Retry goes through dismissing the failure")

        library.cancelJob(config.id)
        #expect(library.jobs[config.id] == nil)
        work.failure = nil
        library.beginSetup(config.id)
        _ = try await work.events.wait(forAtLeast: 2)
        let retry = try #require(library.jobs[config.id])
        #expect(retry !== failed)
        work.finishAll()
        await retry.task?.value
        #expect(library.jobs[config.id] == nil)
    }

    @Test func deletingAMachineWhileItsSetupUnwindsLeavesNoJobBehind() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = StubbornSetup()
        let library = makeLibrary(in: directory, running: work)
        let config = VMConfig.new(name: "unfinished", guest: .linux)
        try library.add(config)
        library.beginSetup(config.id)
        let job = try #require(library.jobs[config.id])
        _ = try await work.events.wait(forAtLeast: 1)

        library.delete(config.id)
        #expect(library.jobs[config.id] == nil)
        #expect(library.machine(config.id) == nil)
        work.finishAll()
        await job.task?.value
        #expect(library.jobs[config.id] == nil)
    }

    @Test func loadingAgainDoesNotDiscardTheDisposableCopyOfARunningMachine() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()
        #expect(rig.disposableCopyExists)

        // A second window running the load task again, or any other caller of the startup sweep.
        rig.library.discardAllEphemeral()
        #expect(rig.disposableCopyExists, "it is the disk the guest is using")

        rig.controller.quit()
        rig.library.discardAllEphemeral()
        #expect(!rig.disposableCopyExists, "a copy nobody uses is left over from a crash, and goes")
    }

    @Test func aRunningMachineCannotBeDuplicatedOrDeleted() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()

        #expect(throws: LibraryError.self) { try rig.library.duplicate(rig.id) }
        #expect(rig.library.machines.count == 1, "no half-made copy")

        let model = rig.library.model(for: rig.id)
        model.delete()
        #expect(rig.library.machine(rig.id) != nil)
        #expect(rig.library.alertMessage?.contains("Stop") == true, "the refusal is not silent")
        #expect(rig.controller.state == .running)
    }

    @Test func quittingLetsEveryControllerGoOfWhatItsMachineHolds() async throws {
        let rig = try ControllerRig(ephemeral: true, runtimeMinutes: 60)
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()

        rig.library.prepareToQuit()
        rig.expectReleased()
        try await rig.expectNetworkBalanced(runs: 1)
    }
}
