import Foundation
import TestKit
import Testing

@testable import VMRunner

/// `--start` says why it did not start a machine, in the log and in the alert, instead of skipping it silently.
struct LaunchStartDecisionTests {
    private func machine(_ name: String, provisioned: Bool) -> VMConfig {
        var config = VMConfig.new(name: name, guest: .linux)
        config.isProvisioned = provisioned
        return config
    }

    @Test func aSetUpMachineIsStarted() {
        let target = machine("build", provisioned: true)
        #expect(LaunchStart.decide("build", in: [machine("other", provisioned: true), target], settingUp: []) == .start(target.id))
        #expect(LaunchStart.decide(target.id.uuidString, in: [target], settingUp: []) == .start(target.id))
    }

    @Test func aMachineThatWasNeverSetUpIsRefusedWithItsName() {
        let target = machine("unfinished", provisioned: false)
        #expect(LaunchStart.decide("unfinished", in: [target], settingUp: []) == .refuse(.notSetUp(name: "unfinished")))
    }

    @Test(arguments: [true, false])
    func aMachineWithASetupInTheTableIsRefusedWhetherOrNotItIsMarkedSetUp(provisioned: Bool) {
        let target = machine("installing", provisioned: provisioned)
        let decision = LaunchStart.decide("installing", in: [target], settingUp: [target.id])
        #expect(decision == .refuse(.settingUp(name: "installing")))
    }

    @Test func aSetupOfAnotherMachineDoesNotBlockThisOne() {
        let target = machine("ready", provisioned: true)
        let busy = machine("busy", provisioned: false)
        #expect(LaunchStart.decide("ready", in: [target, busy], settingUp: [busy.id]) == .start(target.id))
    }

    @Test func anUnknownOrAmbiguousKeyIsRefused() {
        let machines = [machine("dup", provisioned: true), machine("dup", provisioned: true)]
        #expect(LaunchStart.decide("dup", in: machines, settingUp: []) == .refuse(.ambiguous(count: 2)))
        #expect(LaunchStart.decide("missing", in: machines, settingUp: []) == .refuse(.notFound))
    }

    @Test func everyRefusalHasAMessageForTheAlertAndAPrivateSafeReasonForTheLog() {
        let name = "client-secret-project"
        let refusals: [LaunchRefusal] = [.notFound, .ambiguous(count: 3), .settingUp(name: name), .notSetUp(name: name)]
        for refusal in refusals {
            #expect(!refusal.message.isEmpty && !refusal.logReason.isEmpty)
            #expect(!refusal.logReason.contains(name), "the log never carries a machine's name")
        }
        #expect(LaunchRefusal.settingUp(name: name).message.contains(name))
        #expect(LaunchRefusal.notSetUp(name: name).message.contains("Resume Setup"))
    }
}

@MainActor
struct LaunchStartLibraryTests {
    @Test func aRefusedLaunchShowsTheLibraryAlertAndStartsNothing() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        let config = VMConfig.new(name: "unfinished", guest: .linux)
        try library.add(config)

        #expect(library.machineToStart(forLaunchArgument: "unfinished") == nil)

        #expect(library.alertMessage?.contains("unfinished") == true)
        #expect(!library.controller(for: config.id).isActive)
    }

    @Test func aSetUpMachineIsReturnedWithoutAnAlert() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        var config = VMConfig.new(name: "ready", guest: .linux)
        config.isProvisioned = true
        try library.add(config)

        #expect(library.machineToStart(forLaunchArgument: "ready") == config.id)
        #expect(library.alertMessage == nil)
    }

    @Test func aMachineMidSetupIsRefusedAsBeingSetUp() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AsyncGate()
        let library = VMLibrary(machinesDirectory: directory, provision: { _, _, _ in try await gate.waitUntilOpen() })
        let config = VMConfig.new(name: "installing", guest: .linux)
        try library.add(config)
        library.beginSetup(config.id)
        let job = try #require(library.jobs[config.id])

        #expect(library.machineToStart(forLaunchArgument: "installing") == nil)
        #expect(library.alertMessage?.contains("setup is still running") == true)

        library.cancelJob(config.id)
        gate.open()
        await job.task?.value
    }

    @Test func aMachineWhoseSetupFailedIsRefusedToo() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory, provision: { _, _, _ in throw FakeGuestError(message: "no network") })
        var config = VMConfig.new(name: "failed", guest: .linux)
        config.isProvisioned = true
        try library.add(config)
        library.beginSetup(config.id)
        await library.jobs[config.id]?.task?.value
        try #require(library.jobs[config.id] != nil, "a failed job stays in the table for its retry")

        #expect(library.machineToStart(forLaunchArgument: "failed") == nil)
        #expect(library.alertMessage?.contains("failed") == true)
    }
}

/// The load task runs in every window; a second run changes nothing.
@MainActor
struct LibraryLoadTests {
    @Test func loadingAgainKeepsSettingsThatAreStillWaitingToBeWritten() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        var config = VMConfig.new(name: "before", guest: .linux)
        try library.add(config)
        library.load()

        config.name = "after"
        library.update(config)
        library.load()

        #expect(library.machine(config.id)?.name == "after", "the second window's load must not read the old file back over it")
    }

    @Test func loadingAgainDoesNotReadTheFolderAgain() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        library.load()
        let late = VMConfig.new(name: "late", guest: .linux)
        let bundle = VMBundle(id: late.id, in: directory)
        try bundle.create()
        try late.encoded().writePrivately(to: bundle.config)

        library.load()

        #expect(library.machines.isEmpty, "a repeated load is a no-op, not a second scan")
        let reopened = VMLibrary(machinesDirectory: directory)
        reopened.load()
        #expect(reopened.machines.map(\.id) == [late.id], "a new library still sees it")
    }

    @Test func aLoadThatCouldNotReachTheFolderIsTriedAgain() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appending(path: "blocked")
        try Data().write(to: parent)
        let library = VMLibrary(machinesDirectory: parent.appending(path: "Machines"))

        library.load()
        #expect(library.alertMessage != nil)

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        library.alertMessage = nil
        library.load()
        #expect(library.alertMessage == nil)
        #expect(FileManager.default.fileExists(atPath: parent.appending(path: "Machines").path))
    }
}
