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
    var errorMessage: String?

    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var activeBundle: VMBundle?
    @ObservationIgnored private var runtimeLimit: Task<Void, Never>?

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
        if config.networkMode == .nat, config.macAddress.flatMap({ VZMACAddress(string: $0) }) == nil {
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
            let vz = try ConfigurationBuilder.build(config, bundle: bundle, display: display)
            probeSuspendSupport(of: vz, allowed: mayResume)

            var notice: String?
            if bundle.hasSavedState, canSuspend {
                do {
                    try await restore(vz, from: bundle)
                    startRuntimeLimit(minutes: config.maxRuntimeMinutes)
                    return
                } catch {
                    // Saved state is tied to the exact configuration; fall back to a cold boot.
                    Log.machine.error("Restore failed: \(error.localizedDescription, privacy: .public)")
                    bundle.discardSavedState()
                    tearDown()
                    activeBundle = bundle
                    notice = "Couldn't restore the suspended state (\(error.localizedDescription)). Booted normally instead."
                }
            }

            // A configuration that failed to restore can't be reused, so build a fresh one.
            let fresh = notice == nil ? vz : try ConfigurationBuilder.build(config, bundle: bundle, display: display)
            let machine = attach(VZVirtualMachine(configuration: fresh))
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

    private func probeSuspendSupport(of configuration: VZVirtualMachineConfiguration, allowed: Bool) {
        do {
            try configuration.validateSaveRestoreSupport()
            canSuspend = allowed
            suspendUnavailableReason = allowed ? nil : "Suspend is off for disposable or locked-down machines."
        } catch {
            canSuspend = false
            suspendUnavailableReason = error.localizedDescription
        }
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
        runtimeLimit?.cancel()
        guard minutes > 0 else { return }
        deadline = .now.addingTimeInterval(Double(minutes) * 60)
        runtimeLimit = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(minutes * 60))
                self?.requestStop()
                // Give the guest 30 s to shut down cleanly before pulling the plug.
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            await self?.forceStop()
        }
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
        runtimeLimit?.cancel()
        runtimeLimit = nil
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
