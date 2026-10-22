import Foundation
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// The memory image is written under a temporary name and renamed into place, so the final name never holds a partial one.
@MainActor
struct MachineSuspendImageTests {
    private func mode(of file: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    @Test func theImageIsWrittenBesideItsFinalNameAndOnlyTheFinalNameCounts() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let gate = guest.hold(.save)

        let suspending = Task { await rig.controller.suspend() }
        try await guest.waitFor(.save)
        #expect(exists(rig.bundle.savedStateStaging), "being written under the temporary name")
        #expect(rig.bundle.savedStateStaging.deletingLastPathComponent() == rig.bundle.savedState.deletingLastPathComponent())
        #expect(!rig.bundle.hasSavedState, "a crash here would leave nothing a restore could take for an image")

        gate.open()
        await suspending.value
        #expect(rig.bundle.hasSavedState)
        #expect(!exists(rig.bundle.savedStateStaging))
        #expect(try String(contentsOf: rig.bundle.savedState, encoding: .utf8) == "memory")
        #expect(try mode(of: rig.bundle.savedState) == 0o600)
    }

    @Test func committingReplacesAnOlderImageInOneStepAndKeepsItPrivate() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data("old".utf8).write(to: bundle.savedState)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundle.savedState.path)
        try Data("new".utf8).write(to: bundle.savedStateStaging)

        try bundle.commitSavedState()

        #expect(try String(contentsOf: bundle.savedState, encoding: .utf8) == "new")
        #expect(try mode(of: bundle.savedState) == 0o600, "the replaced image's permissions do not come back")
        #expect(!exists(bundle.savedStateStaging))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [bundle.savedState.lastPathComponent])
    }

    @Test func committingWithoutAnImageFailsAndLeavesNoFinalName() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)

        #expect(throws: (any Error).self) { try bundle.commitSavedState() }
        #expect(!bundle.hasSavedState)
    }

    @Test func aSuspendThatFailsToSaveLeavesNeitherAPartialImageNorATemporary() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.save, "the disk is full")

        await rig.controller.suspend()

        #expect(rig.controller.errorMessage == "Couldn't suspend: the disk is full")
        #expect(!rig.bundle.hasSavedState)
        #expect(!exists(rig.bundle.savedStateStaging))
    }

    @Test func aSuspendWhoseStopFailsLeavesNoImageAndNoTemporary() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        guest.fail(.stop, "stuck")

        await rig.controller.suspend()

        #expect(!rig.bundle.hasSavedState)
        #expect(!exists(rig.bundle.savedStateStaging))
    }

    @Test func aSuspendThatEndsWithTheMachineReleasedLeavesNoTemporary() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        let gate = guest.hold(.save)

        let suspending = Task { await rig.controller.suspend() }
        try await guest.waitFor(.save)
        rig.controller.quit()
        gate.open()
        await suspending.value

        #expect(!rig.bundle.hasSavedState)
        #expect(!exists(rig.bundle.savedStateStaging))
    }

    @Test func aTemporaryLeftByACrashIsSweptAtStartAndTheMachineBootsCold() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        try Data("half an image".utf8).write(to: rig.bundle.savedStateStaging)
        #expect(!rig.bundle.hasSavedState)

        await rig.start()

        #expect(!exists(rig.bundle.savedStateStaging))
        #expect(guest.count(.restore) == 0 && guest.count(.start) == 1, "a partial file is never restored")
        #expect(rig.controller.state == .running)
    }

    @Test func aTemporaryBesideARealImageIsSweptAndTheImageIsStillRestored() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        try rig.leaveSavedState()
        try Data("half an image".utf8).write(to: rig.bundle.savedStateStaging)

        await rig.start()

        #expect(!exists(rig.bundle.savedStateStaging))
        #expect(guest.count(.restore) == 1)
        #expect(rig.controller.state == .running)
    }

    @Test func discardingTheSavedStateTakesTheTemporaryToo() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data("a".utf8).write(to: bundle.savedState)
        try Data("b".utf8).write(to: bundle.savedStateStaging)

        bundle.discardSavedState()

        #expect(!exists(bundle.savedState) && !exists(bundle.savedStateStaging))
    }
}
