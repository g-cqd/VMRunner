import ControlProtocol
import Foundation
import Testing

@testable import VMRunner

/// A fixed list of machines for the service tests: nothing is started or stopped.
struct StaticMachines: ControlMachines {
    let list: [ControlMachine]

    func machines() async -> [ControlMachine] { list }
    func start(_ id: UUID) async -> ControlOutcome { .refused("not in this test") }
    func stop(_ id: UUID, force: Bool) async -> ControlOutcome { .refused("not in this test") }
}

/// The library as the control service sees it, with fake machines in a scratch folder.
@MainActor
struct LibraryControlMachinesTests {
    private func open(_ rig: ControllerRig) {
        var config = rig.config
        config.agentAccess = true
        rig.library.update(config)
    }

    @Test
    func theListShowsEachMachineWithItsStateAndItsAccess() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let adapter = LibraryControlMachines(library: rig.library)
        let closed = ControlMachine(id: rig.id, name: "fake", guest: "linux", state: .stopped, agentAccess: false)
        #expect(await adapter.machines() == [closed])
        open(rig)
        #expect(await adapter.machines().first?.agentAccess == true)
    }

    @Test
    func aMachineWithAccessOffIsNeitherStartedNorStoppedEvenWhenAskedDirectly() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        let adapter = LibraryControlMachines(library: rig.library)
        #expect(await adapter.start(rig.id) == .refused("Agent access is off for this machine."))
        #expect(await adapter.stop(rig.id, force: true) == .refused("Agent access is off for this machine."))
        #expect(rig.factory.preparations == 0)
    }

    @Test
    func startAndAForcedStopGoThroughTheLibraryAndAnswerTheNewState() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        open(rig)
        let adapter = LibraryControlMachines(library: rig.library)
        #expect(await adapter.start(rig.id) == .done(.running))
        #expect(await adapter.start(rig.id) == .refused("“fake” is already running."))
        #expect(await adapter.stop(rig.id, force: true) == .done(.stopped))
        rig.expectReleased()
    }

    @Test
    func aCleanStopAsksTheGuestAndAnswersAtOnce() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        open(rig)
        let adapter = LibraryControlMachines(library: rig.library)
        _ = await adapter.start(rig.id)
        #expect(await adapter.stop(rig.id, force: false) == .done(.shuttingDown))
        #expect(guest.count(.requestStop) == 1)
        await rig.controller.forceStop()
    }

    @Test
    func stoppingAMachineThatIsNotRunningIsRefused() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        open(rig)
        #expect(await rig.library.stopAndWait(rig.id, force: false) == .refused("“fake” is not running."))
    }

    @Test
    func everyMachineStateHasTheStateAnAgentSees() {
        let expected: [MachineState: ControlState] = [
            .stopped: .stopped, .starting(.preparing(allowsRestore: true)): .starting,
            .starting(.preparing(allowsRestore: false)): .starting, .starting(.restoring): .starting, .starting(.booting): .starting,
            .running: .running, .shuttingDown: .shuttingDown, .pausing: .pausing, .paused: .paused, .resuming: .resuming,
            .suspending: .suspending, .stopping: .stopping,
        ]
        for state in MachineState.all { #expect(ControlState(state) == expected[state], "\(state)") }
    }
}

/// The app's control service on a short private folder under /tmp (a socket path holds at most 103 bytes); never the app's
/// data folder and never `ControlService.shared`.
@MainActor
struct ControlServiceTests {
    private func shortFolder() throws -> URL {
        let tmp = URL(filePath: "/tmp", directoryHint: .isDirectory)
        let url = tmp.appending(path: "vmrs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func mode(_ path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    @Test
    func turnedOnItListensPrivatelyAndAnswersAndTurnedOffItRemovesTheSocket() async throws {
        let root = try shortFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Control", directoryHint: .isDirectory)
        let machine = ControlMachine(id: UUID(), name: "m", guest: "linux", state: .stopped, agentAccess: true)
        let service = ControlService(directory: directory, machines: StaticMachines(list: [machine]))
        let secret = try service.tokenStore().create(name: "t", capabilities: [.list]).secret

        await service.setRunning(true)
        let path = try #require(service.socketPath)
        #expect(service.failure == nil)
        #expect(try mode(directory.path) == 0o700)
        #expect(try mode(path) == 0o600)
        #expect(try mode(directory.appending(path: "tokens.json").path) == 0o600)

        let answer = try await Task.detached {
            let client = try ControlClient.connect(to: path)
            defer { client.close() }
            return try client.call("machines.list", params: ["token": .string(secret)])
        }.value
        #expect(answer.errorCode == nil)

        await service.setRunning(true)
        #expect(service.socketPath == path, "a second start keeps the one listener")
        await service.setRunning(false)
        #expect(service.socketPath == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        await service.setRunning(true)
        #expect(service.socketPath == path, "turned on again at once, it listens again")
        await service.setRunning(false)
    }

    @Test
    func aDataFolderTooDeepForASocketPathKeepsTheServiceOffAndSaysWhy() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: String(repeating: "d", count: 60), directoryHint: .isDirectory)
        let service = ControlService(directory: directory, machines: StaticMachines(list: []))
        await service.setRunning(true)
        #expect(service.socketPath == nil)
        #expect(service.failure?.contains("holds at most") == true)
        await service.setRunning(false)
        #expect(service.failure == nil, "a service that is off shows no failure")
    }

    @Test
    func theServiceRunsOnlyWhenTheUserTurnedItOnAndTheOrganisationAllowsIt() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let open = ManagedPreferences(forcedValue: { _ in nil })
        #expect(!ControlService.isEnabled(defaults: scratch.defaults, policy: open), "off by default")
        scratch.defaults.set(true, forKey: AppSetting.runsControlService.rawValue)
        #expect(ControlService.isEnabled(defaults: scratch.defaults, policy: open))
        let denied = ManagedPreferences(forcedValue: { $0 == ManagedKey.allowControlService.rawValue ? false as Any : nil })
        #expect(!ControlService.isEnabled(defaults: scratch.defaults, policy: denied))
    }
}
