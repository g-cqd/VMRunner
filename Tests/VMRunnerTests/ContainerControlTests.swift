import ControlProtocol
import Foundation
import TestKit
import Testing

@testable import VMRunner

/// A container machine in the library, with a shell script for the runner and a flag file the script leaves when it is run.
/// Nothing here starts a container or the real runner.
@MainActor
private struct ControlRig {
    static let ready = #"{"event":"phase","name":"run","seconds":0}"#
    /// Says it is ready, then waits for a `stop` line (exit 75) or the end of its input (exit 76).
    static let waitsForStop = "echo '\(ready)'\nread line || exit 76\n[ \"$line\" = stop ] && exit 75\nexit 1"
    /// Says it is ready, ignores its input and SIGTERM, then sleeps: only SIGKILL ends it.
    static let ignoresEverything = "trap '' TERM\necho '\(ready)'\nexec sleep 30"

    let directory: URL
    let library: VMLibrary
    let controller: VMController
    let config: VMConfig

    init(script: String, containersAllowed: Bool = true, agentAccess: Bool = true) throws {
        directory = try scratchDirectory()
        let runner = directory.appending(path: "runner.sh")
        try Data("#!/bin/sh\n: > \"$(dirname \"$0\")/ran\"\n\(script)\n".utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        let machines = directory.appending(path: "Machines", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
        let policy = ManagedPreferences(forcedValue: {
            $0 == ManagedKey.allowContainers.rawValue && !containersAllowed ? false as Any : nil
        })
        let router = RoutingMachineFactory(
            virtualMachines: FakeFactory(), containers: ContainerMachineFactory(runner: runner, policy: { policy }))
        let controller = VMController(factory: router, latency: LatencyActivity(host: ProcessInfo.processInfo, isEnabled: false))
        self.controller = controller
        library = VMLibrary(machinesDirectory: machines, saveDelay: .seconds(3600), makeController: { controller })
        var proposed = VMConfig.newContainer(name: "box")
        proposed.agentAccess = agentAccess
        try library.add(proposed)
        config = library.machine(proposed.id) ?? proposed
    }

    var id: UUID { config.id }
    var adapter: LibraryControlMachines { LibraryControlMachines(library: library) }
    /// Whether the runner script was run at all.
    var runnerRan: Bool { FileManager.default.fileExists(atPath: directory.appending(path: "ran").path) }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Calls made when the workload reports it stopped, after the controller has handled the report.
    func watchStops() throws -> AsyncEventProbe<String> {
        let workload = try #require(controller.guest as? ContainerWorkload)
        let probe = AsyncEventProbe<String>()
        let stopped = workload.onGuestStopped
        workload.onGuestStopped = {
            stopped?()
            probe.record("stopped")
        }
        return probe
    }
}

/// The control service over a library that holds a container machine: what it lists, starts and stops, and what it refuses.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ContainerControlTests {
    private func listed(_ rig: ControlRig, _ state: ControlState) -> ControlMachine {
        ControlMachine(id: rig.id, name: "box", guest: "linux", state: state, agentAccess: true, workload: "container")
    }

    @Test func theListSaysAContainerIsOneAndShowsItsStateAsItStartsAndStops() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop)
        defer { rig.remove() }

        #expect(await rig.adapter.machines() == [listed(rig, .stopped)])
        #expect(await rig.adapter.start(rig.id) == .done(.running))
        #expect(await rig.adapter.machines() == [listed(rig, .running)])
        #expect(await rig.adapter.stop(rig.id, force: true) == .done(.stopped))
        #expect(await rig.adapter.machines() == [listed(rig, .stopped)])
    }

    @Test func aCleanStopAsksTheContainerToStopAndItEndsStopped() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop)
        defer { rig.remove() }

        #expect(await rig.adapter.start(rig.id) == .done(.running))
        let stops = try rig.watchStops()
        #expect(await rig.adapter.stop(rig.id, force: false) == .done(.shuttingDown))
        _ = try await stops.wait(forAtLeast: 1)

        #expect(rig.controller.state == .stopped && rig.controller.guest == nil)
        #expect(rig.controller.errorMessage == nil, "exit 75 is a stop, not an error")
        #expect(await rig.adapter.machines() == [listed(rig, .stopped)])
    }

    @Test func aForcedStopKillsARunnerThatIgnoresEverything() async throws {
        let rig = try ControlRig(script: ControlRig.ignoresEverything)
        defer { rig.remove() }

        #expect(await rig.adapter.start(rig.id) == .done(.running))
        #expect(await rig.adapter.stop(rig.id, force: true) == .done(.stopped))
        #expect(rig.controller.guest == nil && rig.controller.errorMessage == nil)
        #expect(await rig.adapter.stop(rig.id, force: true) == .refused("“box” is not running."))
    }

    @Test func aContainerWithAgentAccessOffIsNeitherStartedNorStopped() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop, agentAccess: false)
        defer { rig.remove() }

        #expect(await rig.adapter.start(rig.id) == .refused("Agent access is off for this machine."))
        #expect(await rig.adapter.stop(rig.id, force: true) == .refused("Agent access is off for this machine."))
        #expect(!rig.runnerRan)
        #expect(rig.controller.state == .stopped)
    }

    @Test func whileTheOrganisationKeepsTheServiceOffNothingIsListedOrStarted() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop)
        defer { rig.remove() }
        let closed = LibraryControlMachines(
            library: rig.library,
            policy: { ManagedPreferences(forcedValue: { $0 == ManagedKey.allowControlService.rawValue ? false as Any : nil }) })

        #expect(await closed.machines().isEmpty)
        #expect(await closed.start(rig.id) == .refused("Your organisation does not allow the control service."))
        #expect(await closed.stop(rig.id, force: true) == .refused("Your organisation does not allow the control service."))
        #expect(!rig.runnerRan)
    }

    @Test func aStartTheOrganisationForbidsIsRefusedWithItsMessageAndTheMachineStaysStopped() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop, containersAllowed: false)
        defer { rig.remove() }

        #expect(await rig.adapter.machines() == [listed(rig, .stopped)], "the machine stays in the list")
        #expect(await rig.adapter.start(rig.id) == .refused(ManagedPreferences.containersDeniedMessage))
        #expect(rig.controller.state == .stopped && rig.controller.guest == nil)
        #expect(!rig.runnerRan)
        #expect(await rig.adapter.stop(rig.id, force: true) == .refused("“box” is not running."))
    }

    /// Puts `text` in the container's output file, as its runs would have.
    private func leaveOutput(_ rig: ControlRig, _ text: String) async {
        let file = ContainerOutputFile(bundle: rig.library.bundle(rig.id))
        file.append(Array(text.utf8))
        await file.drained()
    }

    @Test func theLogOfAContainerIsTheEndOfItsOutputFile() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop)
        defer { rig.remove() }
        #expect(await rig.adapter.log(rig.id) == .text("", truncated: false), "a container that never ran has no log yet")

        await leaveOutput(rig, "hello\n")
        #expect(await rig.adapter.log(rig.id) == .text("hello\n", truncated: false))
        await leaveOutput(rig, String(repeating: "x", count: ControlLog.maxBytes))
        #expect(await rig.adapter.log(rig.id) == .text(String(repeating: "x", count: ControlLog.maxBytes), truncated: true))
    }

    @Test func aContainerWithAgentAccessOffHasNoLogToAnAgent() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop, agentAccess: false)
        defer { rig.remove() }
        await leaveOutput(rig, "secret\n")

        #expect(await rig.adapter.log(rig.id) == .refused("Agent access is off for this machine."))
    }

    @Test func whileTheOrganisationKeepsTheServiceOffTheLogIsClosedToo() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop)
        defer { rig.remove() }
        await leaveOutput(rig, "secret\n")
        let closed = LibraryControlMachines(
            library: rig.library,
            policy: { ManagedPreferences(forcedValue: { $0 == ManagedKey.allowControlService.rawValue ? false as Any : nil }) })

        #expect(await closed.log(rig.id) == .refused("Your organisation does not allow the control service."))
    }

    @Test func aVirtualMachinesEntryIsAsItWasPlusItsWorkload() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let entry = try #require(await LibraryControlMachines(library: rig.library).machines().first)
        #expect(
            entry == ControlMachine(id: rig.id, name: "fake", guest: "linux", state: .stopped, agentAccess: false, workload: "vm"))
    }
}

/// The same machine reached through the service's socket, as a script or an agent reaches it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ContainerControlSocketTests {
    private func shortFolder() throws -> URL {
        let url = URL(filePath: "/tmp", directoryHint: .isDirectory).appending(
            path: "vmrs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// One call on its own connection, made off the main actor so the app can answer it.
    private func call(_ path: String, _ method: String, _ params: [String: RPCValue]) async throws -> ControlAnswer {
        try await Task.detached {
            let client = try ControlClient.connect(to: path)
            defer { client.close() }
            return try client.call(method, params: params)
        }.value
    }

    /// Runs `body` against a service over the rig's library on a private socket, and stops the service afterwards.
    private func withService(
        _ rig: ControlRig, _ body: (_ call: (String, [String: RPCValue]) async throws -> ControlAnswer) async throws -> Void
    ) async throws {
        let root = try shortFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ControlService(directory: root.appending(path: "Control", directoryHint: .isDirectory), machines: rig.adapter)
        let secret = try service.tokenStore().create(name: "t", capabilities: [.list, .state, .start, .stop]).secret
        await service.setRunning(true)
        do {
            let path = try #require(service.socketPath)
            try await body { method, params in
                try await self.call(path, method, params.merging(["token": .string(secret)]) { first, _ in first })
            }
        } catch {
            await service.setRunning(false)
            throw error
        }
        await service.setRunning(false)
    }

    private func object(_ answer: ControlAnswer) throws -> [String: Any] {
        let data = try #require(answer.result)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aScriptListsStartsAndStopsAContainerThroughTheSocket() async throws {
        let rig = try ControlRig(script: ControlRig.ignoresEverything)
        defer { rig.remove() }
        let machine: [String: RPCValue] = ["machine": .string(rig.id.uuidString)]

        try await withService(rig) { call in
            let list = try await call("machines.list", [:])
            let machines = try #require(try object(list)["machines"] as? [[String: Any]])
            #expect(machines.count == 1)
            let entry = try #require(machines.first)
            #expect(Set(entry.keys) == ["id", "name", "guest", "state", "agentAccess", "workload"])
            #expect(entry["workload"] as? String == "container" && entry["guest"] as? String == "linux")
            #expect(entry["state"] as? String == "stopped" && entry["name"] as? String == "box")

            let started = try await call("machines.start", machine)
            #expect(try object(started) as NSDictionary == ["id": rig.id.uuidString, "state": "running"])
            let running = try await call("machines.state", machine)
            #expect(try object(running)["state"] as? String == "running")

            let stopped = try await call("machines.stop", machine.merging(["force": .bool(true)]) { first, _ in first })
            #expect(try object(stopped) as NSDictionary == ["id": rig.id.uuidString, "state": "stopped"])
        }
        #expect(rig.controller.state == .stopped && rig.controller.guest == nil)
    }

    @Test func aStartTheOrganisationForbidsAnswersARefusalWithItsMessage() async throws {
        let rig = try ControlRig(script: ControlRig.waitsForStop, containersAllowed: false)
        defer { rig.remove() }

        try await withService(rig) { call in
            let refused = try await call("machines.start", ["machine": .string(rig.id.uuidString)])
            #expect(refused.errorCode == -32004 && refused.result == nil)
            #expect(refused.errorMessage == "Refused: " + ManagedPreferences.containersDeniedMessage)
            let state = try await call("machines.state", ["machine": .string(rig.id.uuidString)])
            #expect(try object(state)["state"] as? String == "stopped")
        }
        #expect(!rig.runnerRan)
    }
}
