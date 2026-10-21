import Foundation
import Observation
import Virtualization
import os

/// Owns one running `VZVirtualMachine` and mirrors its state for SwiftUI.
///
/// Every callback that can arrive late (KVO, delegate) carries the identity of the machine it came from and
/// is ignored if that machine is no longer the current one, so a machine that failed to restore can't
/// tear down its replacement.
@MainActor @Observable
final class VMController: NSObject, VZVirtualMachineDelegate {
    private(set) var virtualMachine: VZVirtualMachine?
    private(set) var state: VZVirtualMachine.State = .stopped
    private(set) var canSuspend = false
    /// Why Suspend is unavailable, when it is.
    private(set) var suspendUnavailableReason: String?
    /// When the runtime limit will shut the machine down, if one is set.
    private(set) var deadline: Date?
    /// The live view of this run's filtered network; `nil` for other network modes and while stopped.
    private(set) var network: NetworkActivity?
    var errorMessage: String?

    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var activeBundle: VMBundle?
    @ObservationIgnored private let runtimeLimit = RuntimeLimit(clock: ContinuousClock())

    var isActive: Bool { virtualMachine != nil }

    // MARK: Start

    /// Boots the machine, restoring saved state when present.
    ///
    /// Failures are reported through `errorMessage`; the controller is back in its stopped state afterwards.
    func start(_ config: VMConfig, bundle: VMBundle, library: VMLibrary, windowSize: CGSize? = nil) async {
        guard virtualMachine == nil else { return }
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
        let display = ConfigurationBuilder.displaySize(for: config, windowSize: windowSize, restoring: restoring)
        if !restoring {
            config.lastDisplayWidth = display.width
            config.lastDisplayHeight = display.height
            library.update(config)
        }

        do {
            if config.ephemeral { try bundle.prepareEphemeral(guest: config.guest) }
            activeBundle = bundle
            var built = try ConfigurationBuilder.build(config, bundle: bundle, display: display)
            beginNetwork(built.networkStack, policy: config.networkPolicy)
            probeSuspendSupport(of: built.configuration, allowed: mayResume, filtered: config.networkMode == .filtered)

            var notice: String?
            if bundle.hasSavedState, canSuspend {
                do {
                    try await restore(built.configuration, from: bundle)
                    startRuntimeLimit(minutes: config.maxRuntimeMinutes)
                    return
                } catch {
                    // Saved state is tied to the exact configuration; fall back to a cold boot.
                    Log.machine.error("Restore failed: \(error.localizedDescription, privacy: .public)")
                    bundle.discardSavedState()
                    tearDown()
                    activeBundle = bundle
                    notice = "Couldn't restore the suspended state (\(error.localizedDescription)). Booted normally instead."
                    // A configuration that failed to restore can't be reused, and neither can its network stack.
                    built = try ConfigurationBuilder.build(config, bundle: bundle, display: display)
                    beginNetwork(built.networkStack, policy: config.networkPolicy)
                }
            }

            let machine = attach(VZVirtualMachine(configuration: built.configuration))
            switch config.guest {
            case .macOS:
                try await machine.start(options: try macStartOptions(config))
            case .linux:
                try await machine.start()
            }
            // Stopped (for example force-stopped) while the start was still in flight: nothing more to do.
            guard virtualMachine === machine else { return }

            recordFirstBoot(of: config, in: library)
            errorMessage = notice
            startRuntimeLimit(minutes: config.maxRuntimeMinutes)
        } catch {
            Log.machine.error("Start failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            tearDown()
        }
    }

    private func probeSuspendSupport(of configuration: VZVirtualMachineConfiguration, allowed: Bool, filtered: Bool) {
        do {
            try configuration.validateSaveRestoreSupport()
            canSuspend = allowed
            suspendUnavailableReason = allowed ? nil : "Suspend is off for disposable or locked-down machines."
        } catch {
            canSuspend = false
            // The framework decides whether a user-mode network device can be saved; say so instead of leaving a bare error.
            suspendUnavailableReason =
                filtered
                ? "\(error.localizedDescription) Filtered networking may be the cause: switch the network to NAT to suspend."
                : error.localizedDescription
        }
    }

    /// Starts a new run's user-mode stack before the machine, and watches it. A stack left from an earlier attempt is
    /// stopped first, because each start gets its own.
    func beginNetwork(_ stack: UserNetStack?, policy: NetworkPolicy) {
        network?.stop()
        guard let stack else {
            network = nil
            return
        }
        let activity = NetworkActivity(stack: stack, policy: policy)
        activity.start()
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

    private func restore(_ vz: VZVirtualMachineConfiguration, from bundle: VMBundle) async throws {
        let machine = attach(VZVirtualMachine(configuration: vz))
        try await machine.restoreMachineStateFrom(url: bundle.savedState)
        bundle.discardSavedState()
        try await machine.resume()
    }

    private func attach(_ machine: VZVirtualMachine) -> VZVirtualMachine {
        machine.delegate = self
        virtualMachine = machine
        observe(machine)
        return machine
    }

    private func macStartOptions(_ config: VMConfig) throws -> VZMacOSVirtualMachineStartOptions {
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = config.bootIntoRecovery

        // The framework only evaluates provisioning on the first boot after install.
        if #available(macOS 27.0, *), !config.hasBooted, config.provisioning.enabled, !config.provisioning.password.isEmpty {
            let provisioning = VZMacGuestProvisioningOptions()
            provisioning.fullName = config.provisioning.fullName
            provisioning.username = config.provisioning.username
            provisioning.password = config.provisioning.password
            provisioning.logsInAutomatically = config.provisioning.logsInAutomatically
            provisioning.enablesRemoteLogin = config.provisioning.enablesRemoteLogin
            try provisioning.validate()
            try options.setGuestProvisioning(provisioning)
        }
        return options
    }

    // MARK: Control

    /// Asks the guest to shut down cleanly (like pressing the power button).
    func requestStop() {
        do { try virtualMachine?.requestStop() } catch { errorMessage = error.localizedDescription }
    }

    /// Stops immediately, like pulling the power cord, and releases the machine.
    func forceStop() async {
        guard let machine = virtualMachine else { return }
        if machine.canStop {
            do { try await machine.stop() } catch { errorMessage = error.localizedDescription }
        }
        if virtualMachine === machine { tearDown() }
    }

    func pause() async {
        do { try await virtualMachine?.pause() } catch { errorMessage = error.localizedDescription }
    }

    func resume() async {
        do { try await virtualMachine?.resume() } catch { errorMessage = error.localizedDescription }
    }

    /// Pauses, writes the machine state to the bundle, then stops. The next start restores it.
    ///
    /// If any step fails the state file is removed: a memory image next to a disk that keeps changing would
    /// restore into a corrupted guest.
    func suspend(to bundle: VMBundle) async {
        guard let machine = virtualMachine, canSuspend else { return }
        do {
            if machine.state == .running { try await machine.pause() }
            try await machine.saveMachineStateTo(url: bundle.savedState)
            try bundle.restrictSavedState()
            try await machine.stop()
            if virtualMachine === machine { tearDown() }
        } catch {
            bundle.discardSavedState()
            errorMessage = "Couldn't suspend: \(error.localizedDescription)"
        }
    }

    // MARK: State plumbing

    private func observe(_ machine: VZVirtualMachine) {
        state = machine.state
        let identity = ObjectIdentifier(machine)
        observation = machine.observe(\.state, options: [.new]) { [weak self] _, change in
            guard let newState = change.newValue else { return }
            Task { @MainActor in
                guard let self, let current = self.virtualMachine, ObjectIdentifier(current) == identity else { return }
                self.state = newState
            }
        }
    }

    private func tearDown() {
        network?.stop()
        network = nil
        runtimeLimit.cancel()
        deadline = nil
        activeBundle?.discardEphemeral()
        activeBundle = nil
        observation = nil
        virtualMachine = nil
        state = .stopped
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let identity = ObjectIdentifier(virtualMachine)
        Task { @MainActor in
            guard let current = self.virtualMachine, ObjectIdentifier(current) == identity else { return }
            self.tearDown()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let identity = ObjectIdentifier(virtualMachine)
        let message = error.localizedDescription
        Task { @MainActor in
            guard let current = self.virtualMachine, ObjectIdentifier(current) == identity else { return }
            self.errorMessage = "The virtual machine stopped: \(message)"
            self.tearDown()
        }
    }
}
