import Foundation
import TestKit
import Testing

@testable import VMRunner

/// Setup work that does not stop when asked to, as an installer that takes a while to unwind does: it finishes when the
/// test says so, then reports the cancellation.
@MainActor
private final class StubbornSetup {
    let events = AsyncEventProbe<String>()
    private(set) var active = 0
    private(set) var mostAtOnce = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run() async throws {
        active += 1
        mostAtOnce = max(mostAtOnce, active)
        events.record("started")
        await withCheckedContinuation { waiting.append($0) }
        active -= 1
        try Task.checkCancellation()
    }

    func finishAll() {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume() }
    }

    /// Lets the run that started first finish; the others keep going.
    func finishOldest() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}

@MainActor
struct LibraryMachineTests {
    @Test func resumingASetupRightAfterCancellingNeverRunsTwoAtOnce() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = StubbornSetup()
        let library = VMLibrary(machinesDirectory: directory, provision: { _, _, _ in try await work.run() })
        let config = VMConfig.new(name: "unfinished", guest: .linux)
        try library.add(config)

        library.beginSetup(config.id)
        let first = try #require(library.jobs[config.id])
        _ = try await work.events.wait(forAtLeast: 1)

        library.cancelJob(config.id)
        library.beginSetup(config.id)
        for _ in 0..<20 { await Task.yield() }
        withKnownIssue("Resume Setup starts a second run while the cancelled one is still unwinding") {
            #expect(work.mostAtOnce == 1)
        }

        work.finishAll()
        await first.task?.value
        await library.jobs[config.id]?.task?.value
        work.finishAll()
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func aFinishedJobNeverClearsTheJobThatReplacedIt() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = StubbornSetup()
        let library = VMLibrary(machinesDirectory: directory, provision: { _, _, _ in try await work.run() })
        let config = VMConfig.new(name: "unfinished", guest: .linux)
        try library.add(config)

        library.beginSetup(config.id)
        let first = try #require(library.jobs[config.id])
        _ = try await work.events.wait(forAtLeast: 1)
        library.cancelJob(config.id)
        library.beginSetup(config.id)
        for _ in 0..<20 { await Task.yield() }

        work.finishOldest()
        await first.task?.value
        for _ in 0..<20 { await Task.yield() }
        if work.active > 0 {
            withKnownIssue("the cancelled job removes the new job from the table") {
                #expect(library.jobs[config.id] != nil, "a setup is running and the screen no longer shows it")
            }
        }
        work.finishAll()
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func loadingAgainDoesNotDiscardTheDisposableCopyOfARunningMachine() async throws {
        let rig = try ControllerRig(ephemeral: true)
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()
        #expect(rig.disposableCopyExists)

        // A second window running the load task again, or any other caller of the startup sweep.
        rig.library.discardAllEphemeral()
        withKnownIssue("the sweep deletes the copy a running machine is using") {
            #expect(rig.disposableCopyExists)
        }
    }

    @Test func aRunningMachineCannotBeDuplicated() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()

        withKnownIssue("an APFS clone of a disk the guest is writing is not a consistent disk") {
            #expect(throws: (any Error).self) { try rig.library.duplicate(rig.id) }
        }
    }
}
