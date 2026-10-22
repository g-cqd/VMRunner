import Foundation
import Observation
import Virtualization
import os

/// Owns one running machine behind the `GuestMachine` seam and mirrors its state for SwiftUI.
///
/// Every callback that can arrive late (state changes, the guest stopping) carries the identity of the machine it came
/// from and is ignored if that machine is no longer the current one, so a machine that failed to restore can't tear down
/// its replacement.
@MainActor @Observable
final class VMController {
    private(set) var guest: (any GuestMachine)?
    private(set) var state: VZVirtualMachine.State = .stopped
    private(set) var canSuspend = false
    /// Why Suspend is unavailable, when it is.
    private(set) var suspendUnavailableReason: String?
    /// When the runtime limit will shut the machine down, if one is set.
    private(set) var deadline: Date?
    /// The live view of this run's filtered network; `nil` for other network modes and while stopped.
    private(set) var network: NetworkActivity?
    var errorMessage: String?

    @ObservationIgnored private var activeBundle: VMBundle?
    @ObservationIgnored private let factory: any MachineFactory
    @ObservationIgnored private let runtimeLimit: RuntimeLimit

    init(factory: any MachineFactory = VZMachineFactory(), runtimeLimit: RuntimeLimit = RuntimeLimit(clock: ContinuousClock())) {
        self.factory = factory
        self.runtimeLimit = runtimeLimit
    }

    /// The framework's machine, for the view that displays it.
    var virtualMachine: VZVirtualMachine? { guest?.virtualMachine }
    var isActive: Bool { guest != nil }

    /// When the current run began its firmware (a cold boot); `nil` while stopped and for a run restored from saved state.
    private(set) var firmwareStartedAt: ContinuousClock.Instant?

    // MARK: Start

    /// Boots the machine, restoring saved state when present.
    ///
    /// Failures are reported through `errorMessage`; the controller is back in its stopped state afterwards.
    func start(_ config: VMConfig, bundle: VMBundle, library: VMLibrary, windowSize: CGSize? = nil) async {
        guard guest == nil else { return }
        errorMessage = nil
        var config = config
        // Without a stored MAC, Virtualization picks a random one per boot, which makes saved state unrestorable.
        if config.networkMode.hasNetworkDevice, config.macAddress.flatMap({ VZMACAddress(string: $0) }) == nil {
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            library.update(config)
        }
        // A memory snapshot is only valid for the exact disk it was taken against, and disposable or
        // locked-down machines must never leave one behind.
        let mayResume = config.allowsSuspend && !config.ephemeral
        if !mayResume { bundle.discardSavedState() }
        let restoring = bundle.hasSavedState
        let display = StartDisplay.size(for: config, window: windowSize, restoring: restoring)
        let window = windowSize.map(DisplayDiagnostics.text) ?? "unknown size"
        Log.display.info(
            "Starting display \(display.width)×\(display.height) px for a window of \(window, privacy: .public) pt, restoring \(restoring)")
        if !restoring {
            config.lastDisplayWidth = display.width
            config.lastDisplayHeight = display.height
            library.update(config)
        }

        do {
            if config.ephemeral { try bundle.prepareEphemeral(guest: config.guest) }
            activeBundle = bundle
            var prepared = try factory.prepare(config, bundle: bundle, display: display, suspendAllowed: mayResume)
            beginNetwork(prepared.network)
            applySuspendSupport(prepared.suspend)

            var notice: String?
            if bundle.hasSavedState, canSuspend {
                do {
                    try await restore(prepared.machine, from: bundle)
                    startRuntimeLimit(minutes: config.maxRuntimeMinutes)
                    return
                } catch {
                    // Saved state is tied to the exact configuration; fall back to a cold boot.
                    Log.machine.error(
                        "Restore failed (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
                    bundle.discardSavedState()
                    tearDown()
                    activeBundle = bundle
                    notice = "Couldn't restore the suspended state (\(error.localizedDescription)). Booted normally instead."
                    // A configuration that failed to restore can't be reused, and neither can its network stack.
                    prepared = try factory.prepare(config, bundle: bundle, display: display, suspendAllowed: mayResume)
                    beginNetwork(prepared.network)
                }
            }

            firmwareStartedAt = .now
            let machine = attach(prepared.machine)
            try await machine.start()
            // Stopped (for example force-stopped) while the start was still in flight: nothing more to do.
            guard guest === machine else { return }

            recordFirstBoot(of: config, in: library)
            errorMessage = notice
            startRuntimeLimit(minutes: config.maxRuntimeMinutes)
        } catch {
            Log.machine.error("Start failed (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            tearDown()
        }
    }

    private func applySuspendSupport(_ support: SuspendSupport) {
        switch support {
        case .available:
            canSuspend = true
            suspendUnavailableReason = nil
        case .unavailable(let reason):
            canSuspend = false
            suspendUnavailableReason = reason
        }
    }

    /// Starts a new run's user-mode stack before the machine, and watches it. A stack left from an earlier attempt is
    /// stopped first, because each start gets its own.
    func beginNetwork(_ stack: UserNetStack?, policy: NetworkPolicy) {
        beginNetwork(stack.map { NetworkActivity(stack: $0, policy: policy) })
    }

    private func beginNetwork(_ activity: NetworkActivity?) {
        network?.stop()
        activity?.start()
        network = activity
    }

    /// Forwards an edited policy to the running stack, if there is one. Other network settings apply at the next start.
    func networkPolicyDidChange(_ policy: NetworkPolicy) {
        network?.apply(policy)
    }

    /// Provisioning is only consumed by a boot that keeps its result: a disposable clone or a recovery boot
    /// would discard the account that was just created.
    private func recordFirstBoot(of config: VMConfig, in library: VMLibrary) {
        guard !config.hasBooted, !config.ephemeral, !config.bootIntoRecovery else { return }
        var updated = config
        updated.hasBooted = true
        updated.provisioning.password = ""
        library.update(updated)
    }

    private func startRuntimeLimit(minutes: Int) {
        runtimeLimit.cancel()
        guard let limit = RuntimeLimit.duration(forMinutes: minutes) else { return }
        deadline = .now.addingTimeInterval(Double(limit.components.seconds))
        runtimeLimit.start(
            after: limit,
            requestStop: { [weak self] in self?.requestStop() },
            forceStop: { [weak self] in await self?.forceStop() }
        )
    }

    private func restore(_ machine: any GuestMachine, from bundle: VMBundle) async throws {
        let machine = attach(machine)
        try await machine.restoreState(from: bundle.savedState)
        bundle.discardSavedState()
        try await machine.resume()
    }

    private func attach(_ machine: any GuestMachine) -> any GuestMachine {
        guest = machine
        LatencyActivity.shared.hold(for: ObjectIdentifier(self))
        let identity = ObjectIdentifier(machine)
        machine.onGuestStopped = { [weak self] in self?.guestDidStop(identity) }
        machine.onStoppedWithError = { [weak self] message in self?.guestDidStop(identity, error: message) }
        observe(machine)
        return machine
    }

    // MARK: Control

    /// Asks the guest to shut down cleanly (like pressing the power button).
    func requestStop() {
        do { try guest?.requestStop() } catch { errorMessage = error.localizedDescription }
    }

    /// Stops immediately, like pulling the power cord, and releases the machine.
    func forceStop() async {
        guard let machine = guest else { return }
        if machine.canStop {
            do { try await machine.stop() } catch { errorMessage = error.localizedDescription }
        }
        if guest === machine { tearDown() }
    }

    func pause() async {
        do { try await guest?.pause() } catch { errorMessage = error.localizedDescription }
    }

    func resume() async {
        do { try await guest?.resume() } catch { errorMessage = error.localizedDescription }
    }

    /// Pauses, writes the machine state to the bundle, then stops. The next start restores it.
    ///
    /// If any step fails the state file is removed: a memory image next to a disk that keeps changing would
    /// restore into a corrupted guest.
    func suspend(to bundle: VMBundle) async {
        guard let machine = guest, canSuspend else { return }
        do {
            if machine.state == .running { try await machine.pause() }
            try await machine.saveState(to: bundle.savedState)
            try bundle.restrictSavedState()
            try await machine.stop()
            if guest === machine { tearDown() }
        } catch {
            bundle.discardSavedState()
            errorMessage = "Couldn't suspend: \(error.localizedDescription)"
        }
    }

    // MARK: State plumbing

    private func observe(_ machine: any GuestMachine) {
        state = machine.state
        let identity = ObjectIdentifier(machine)
        machine.onStateChange = { [weak self] newState in
            guard let self, let current = self.guest, ObjectIdentifier(current) == identity else { return }
            self.state = newState
        }
    }

    private func tearDown() {
        network?.stop()
        network = nil
        runtimeLimit.cancel()
        deadline = nil
        activeBundle?.discardEphemeral()
        activeBundle = nil
        guest = nil
        LatencyActivity.shared.release(for: ObjectIdentifier(self))
        firmwareStartedAt = nil
        state = .stopped
    }

    private func guestDidStop(_ identity: ObjectIdentifier, error: String? = nil) {
        guard let current = guest, ObjectIdentifier(current) == identity else { return }
        if let error { errorMessage = "The virtual machine stopped: \(error)" }
        tearDown()
    }
}
