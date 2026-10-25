import Foundation
import Testing

@testable import VMRunner

/// A workload that keeps every default: no screen, no pause, no saved state.
@MainActor
private final class LogOnlyWorkload: Workload {
    var capabilities: WorkloadCapabilities { [] }
    var canStop: Bool { true }
    var onGuestStopped: (@MainActor () -> Void)?
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)?
    var networkCutoff: NetworkCutoff? { nil }
    func start() async throws {}
    func requestStop() throws {}
    func stop() async throws {}
}

/// What a machine can do is a value the controller and the interface read, not a type they test for.
@MainActor
struct WorkloadCapabilityTests {
    @Test func aVirtualMachineHasEveryCapability() {
        let all: WorkloadCapabilities = [.display, .pause, .suspend, .networkActivity]
        #expect(WorkloadCapabilities.virtualMachine == all)
        #expect(FakeGuest().capabilities == .virtualMachine)
    }

    @Test func aWorkloadKeepingTheDefaultsRefusesWhatItCannotDo() async {
        let workload = LogOnlyWorkload()
        let url = URL(fileURLWithPath: "/nonexistent")
        await #expect(throws: WorkloadUnsupportedError(operation: "pausing")) { try await workload.pause() }
        await #expect(throws: WorkloadUnsupportedError(operation: "resuming")) { try await workload.resume() }
        await #expect(throws: WorkloadUnsupportedError(operation: "suspending")) { try await workload.saveState(to: url) }
        await #expect(throws: WorkloadUnsupportedError(operation: "restoring saved state")) {
            try await workload.restoreState(from: url)
        }
    }
}

/// The controller and the machine model offer a control only for a workload that has it, and a virtual machine is unchanged.
@MainActor
struct WorkloadControlsTests {
    @Test func aVirtualMachineKeepsEveryControl() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.controller.capabilities == .virtualMachine)
        #expect(rig.controller.canPause)
        #expect(rig.controller.canSuspend)
        let model = rig.library.model(for: rig.id)
        #expect(model.canPause && model.canSuspend)
        #expect(model.networkActivity != nil)
        // The fake has no framework machine, so the pane stays on the settings, as before.
        guard case .editing = model.phase else {
            Issue.record("expected the settings pane, got \(String(describing: model.phase))")
            return
        }
        guest.powerOff()
        rig.expectReleased()
    }

    @Test func aWorkloadWithoutAScreenPauseOrSuspendOffersNone() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        guest.capabilities = []
        let shown = ContainerLog()
        guest.workloadLog = shown
        await rig.start()
        #expect(rig.controller.state == .running)
        #expect(!rig.controller.canPause)
        #expect(!rig.controller.canSuspend)
        #expect(rig.controller.suspendUnavailableReason == "This kind of machine can't be suspended.")
        let model = rig.library.model(for: rig.id)
        #expect(!model.canPause && !model.canSuspend)
        #expect(model.networkActivity == nil)
        guard case .running(.workloadLog(let log)) = model.phase else {
            Issue.record("expected the log pane, got \(String(describing: model.phase))")
            return
        }
        #expect(log === shown)
        guest.powerOff()
        rig.expectReleased()
    }

    @Test func nothingIsOfferedBeforeAMachineExists() throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        #expect(rig.controller.capabilities.isEmpty)
        #expect(!rig.controller.canPause)
        guard case .editing = rig.library.model(for: rig.id).phase else {
            Issue.record("expected the settings pane")
            return
        }
    }
}

/// A start goes to the factory of what the machine runs.
@MainActor
struct WorkloadRoutingTests {
    private let display = (width: 1280, height: 800)

    @Test func eachStartGoesToTheFactoryOfItsWorkload() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machines = FakeFactory()
        let containers = FakeFactory()
        machines.add("vm")
        containers.add("box")
        let router = RoutingMachineFactory(virtualMachines: machines, containers: containers)
        let bundle = VMBundle(url: directory)

        let machine = try await router.prepare(
            VMConfig.new(name: "vm", guest: .linux), bundle: bundle, display: display, suspendAllowed: true)
        #expect((machine.machine as? FakeGuest)?.name == "vm")
        #expect(machines.preparations == 1 && containers.preparations == 0)

        let box = try await router.prepare(
            VMConfig.newContainer(name: "box"), bundle: bundle, display: display, suspendAllowed: true)
        #expect((box.machine as? FakeGuest)?.name == "box")
        #expect(machines.preparations == 1 && containers.preparations == 1)
        #expect(containers.bootedConfigs.map(\.workload) == [.container])
    }

    @Test func aBuildWithoutTheRunnerRefusesEveryContainerStart() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machines = FakeFactory()
        let router = RoutingMachineFactory(
            virtualMachines: machines, containers: ContainerMachineFactory(runner: directory.appending(path: "absent")))
        await #expect(throws: ContainerProcessError(reason: ContainerMachineFactory.missingRunnerMessage)) {
            _ = try await router.prepare(
                VMConfig.newContainer(name: "box"), bundle: VMBundle(url: directory), display: display, suspendAllowed: true)
        }
        #expect(machines.preparations == 0)
    }

    @Test func aContainerStartThatCannotBePreparedIsReportedAndLeavesTheControllerStopped() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        let config = VMConfig.newContainer(name: "box")
        try library.add(config)
        let machines = FakeFactory()
        let router = RoutingMachineFactory(
            virtualMachines: machines, containers: ContainerMachineFactory(runner: directory.appending(path: "absent")))
        let controller = VMController(factory: router)

        await controller.start(config, bundle: library.bundle(config.id), library: library)

        #expect(controller.errorMessage == ContainerMachineFactory.missingRunnerMessage)
        #expect(controller.state == .stopped)
        #expect(controller.guest == nil)
        #expect(machines.preparations == 0)
    }
}
