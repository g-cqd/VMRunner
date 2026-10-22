import Foundation
import NetPolicy
import NetStack
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// Hands the controller fake machines, and a network stack that only counts its starts and stops.
@MainActor
final class FakeFactory: MachineFactory {
    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    private var queued: [FakeGuest] = []
    /// Every machine handed out, in order.
    private(set) var handedOut: [FakeGuest] = []
    private(set) var preparations = 0
    /// The display size each preparation was asked for, in order.
    private(set) var displays: [Size] = []
    var suspend = SuspendSupport.available
    var withNetwork = true
    /// `prepare` throws this once, then behaves again.
    var failure: String?
    /// `begin#n` and `shutdown#n` for the n-th preparation's stack.
    let network = AsyncEventProbe<String>()
    /// `held#n` when the n-th preparation starts waiting at the gate `holdPreparation()` set.
    let held = AsyncEventProbe<String>()
    private var preparationGate: AsyncGate?

    /// The next `prepare` waits at the returned gate until the test opens it.
    @discardableResult func holdPreparation() -> AsyncGate {
        let gate = AsyncGate()
        preparationGate = gate
        return gate
    }

    @discardableResult
    func add(_ name: String = "guest") -> FakeGuest {
        let guest = FakeGuest(name)
        queued.append(guest)
        return guest
    }

    func prepare(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine {
        preparations += 1
        displays.append(Size(width: display.width, height: display.height))
        if let gate = preparationGate {
            preparationGate = nil
            held.record("held#\(preparations)")
            try await gate.waitUntilOpen()
        }
        if let failure {
            self.failure = nil
            throw FakeGuestError(message: failure)
        }
        guard !queued.isEmpty else { throw FakeGuestError(message: "the test queued no machine") }
        let guest = queued.removeFirst()
        handedOut.append(guest)
        return PreparedMachine(
            machine: guest, network: withNetwork ? makeNetwork(preparations) : nil,
            suspend: suspendAllowed ? suspend : .unavailable(reason: "Suspend is off for disposable or locked-down machines."))
    }

    private func makeNetwork(_ number: Int) -> NetworkActivity {
        let (flows, _) = AsyncStream.makeStream(of: FlowEvent.self)
        let (vpn, _) = AsyncStream.makeStream(of: GuestVPNState.self)
        let (host, _) = AsyncStream.makeStream(of: [InterfaceSnapshot].self)
        let probe = network
        return NetworkActivity(
            policy: NetworkPolicy(), events: flows, vpnChanges: vpn, hostMonitor: VPNMonitor(source: { host }),
            begin: { probe.record("begin#\(number)") }, forward: { _, _ in },
            shutdown: { probe.record("shutdown#\(number)") })
    }
}

/// Stands in for the process: an activity begins and ends without telling the system.
private final class CountingActivityHost: ActivityHost {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol { NSObject() }
    func endActivity(_ activity: any NSObjectProtocol) {}
}

/// One Linux machine in a scratch folder, a library that knows it, and a controller wired to fakes and a test clock.
@MainActor
final class ControllerRig {
    let directory: URL
    let library: VMLibrary
    let factory = FakeFactory()
    let clock = TestClock()
    /// The latency activity the controller holds while a machine exists, on a host that touches nothing.
    let activity = LatencyActivity(host: CountingActivityHost(), isEnabled: true)
    let controller: VMController
    let id: UUID

    init(ephemeral: Bool = false, runtimeMinutes: Int = 0, allowsSuspend: Bool = true) throws {
        directory = try scratchDirectory()
        let controller = VMController(factory: factory, runtimeLimit: RuntimeLimit(clock: clock), latency: activity)
        self.controller = controller
        library = VMLibrary(machinesDirectory: directory, makeController: { controller })
        var config = VMConfig.new(name: "fake", guest: .linux)
        config.isProvisioned = true
        config.ephemeral = ephemeral
        config.maxRuntimeMinutes = runtimeMinutes
        config.allowsSuspend = allowsSuspend
        id = config.id
        try library.add(config)
        let bundle = library.bundle(config.id)
        try Data("disk".utf8).write(to: bundle.disk)
        try Data("nvram".utf8).write(to: bundle.efiVariables)
        _ = library.controller(for: id)
    }

    var bundle: VMBundle { library.bundle(id) }
    var config: VMConfig { library.machine(id) ?? VMConfig.new(name: "gone", guest: .linux) }

    func start(window: CGSize? = nil) async {
        await controller.start(config, bundle: bundle, library: library, windowSize: window)
    }

    /// Runs `start()` in its own task, so the test can act while it waits for the framework.
    func starting() -> Task<Void, Never> {
        Task { await start() }
    }

    /// The size an earlier cold boot recorded as its start size.
    func remember(width: Int, height: Int) {
        var config = config
        config.lastDisplayWidth = width
        config.lastDisplayHeight = height
        library.update(config)
    }

    /// A memory image from an earlier suspend.
    func leaveSavedState() throws {
        try Data("memory".utf8).write(to: bundle.savedState)
    }

    var disposableCopyExists: Bool { FileManager.default.fileExists(atPath: bundle.ephemeralDisk.path) }

    /// The run is over and nothing it held remains.
    func expectReleased(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(controller.state == .stopped, sourceLocation: sourceLocation)
        #expect(controller.guest == nil, sourceLocation: sourceLocation)
        #expect(controller.virtualMachine == nil, sourceLocation: sourceLocation)
        #expect(controller.network == nil, sourceLocation: sourceLocation)
        #expect(controller.deadline == nil, sourceLocation: sourceLocation)
        #expect(!controller.canSuspend, sourceLocation: sourceLocation)
        #expect(controller.suspendUnavailableReason == nil, sourceLocation: sourceLocation)
        #expect(!disposableCopyExists, sourceLocation: sourceLocation)
        #expect(clock.sleeperCount == 0, "the runtime limit is still counting", sourceLocation: sourceLocation)
        #expect(!activity.isHeld, "the latency activity outlived the machine", sourceLocation: sourceLocation)
    }

    /// Every stack that was started was stopped.
    func expectNetworkBalanced(runs: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let events = try await factory.network.wait(forAtLeast: 2 * runs)
        #expect(events.filter { $0.hasPrefix("begin") }.count == runs, sourceLocation: sourceLocation)
        #expect(events.filter { $0.hasPrefix("shutdown") }.count == runs, sourceLocation: sourceLocation)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
