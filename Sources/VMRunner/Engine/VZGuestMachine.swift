import Foundation
import GuestConsole
import Virtualization

/// A `VZVirtualMachine` behind the controller's seam. It is also the machine's delegate, and forwards the callbacks that
/// arrive on the framework's queue to the main actor.
@MainActor
final class VZGuestMachine: NSObject, GuestMachine, VZVirtualMachineDelegate {
    let machine: VZVirtualMachine
    /// Serves the guest's serial console on a local socket. It starts with the machine and ends when this object is released
    /// (or earlier, when the guest side of the port closes), so the socket exists exactly while the machine can use it.
    private let console: ConsoleBridge?
    /// Evaluated at start, not at creation: a restore never needs them, and a bad provisioning setup must fail the start.
    private let startOptions: () throws -> VZMacOSVirtualMachineStartOptions?
    /// The kill switch of this run, when the machine has a VPN or metered-network rule. It starts with the machine and
    /// ends when this object is released.
    let networkCutoff: NetworkCutoff?
    /// The attachment the kill switch took off the network card, kept to put back.
    private var detachedAttachment: VZNetworkDeviceAttachment?

    var onGuestStopped: (@MainActor () -> Void)?
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)?

    init(
        machine: VZVirtualMachine, console: ConsoleBridge? = nil, networkCutoff: NetworkCutoff? = nil,
        startOptions: @escaping () throws -> VZMacOSVirtualMachineStartOptions?
    ) {
        self.machine = machine
        self.console = console
        self.networkCutoff = networkCutoff
        self.startOptions = startOptions
        super.init()
        machine.delegate = self
    }

    var virtualMachine: VZVirtualMachine? { machine }
    var canStop: Bool { machine.canStop }

    func start() async throws {
        console?.start()
        if let options = try startOptions() {
            try await machine.start(options: options)
        } else {
            try await machine.start()
        }
        startNetworkCutoff()
    }

    func restoreState(from url: URL) async throws {
        console?.start()
        try await machine.restoreMachineStateFrom(url: url)
        startNetworkCutoff()
    }
    func saveState(to url: URL) async throws { try await machine.saveMachineStateTo(url: url) }
    func pause() async throws { try await machine.pause() }
    func resume() async throws { try await machine.resume() }
    func requestStop() throws { try machine.requestStop() }
    func stop() async throws { try await machine.stop() }

    /// Starts the kill switch once the framework has the machine, so its network card can be reached.
    private func startNetworkCutoff() {
        networkCutoff?.start { [weak self] connected in self?.setNetworkConnected(connected) }
    }

    /// Takes the attachment off the network card (`false`) or puts the one it had back (`true`), like pulling and
    /// replugging a cable. A change the framework refuses is reported to the delegate and leaves the card disconnected.
    private func setNetworkConnected(_ connected: Bool) {
        guard let device = machine.networkDevices.first else { return }
        if connected {
            guard let attachment = detachedAttachment else { return }
            device.attachment = attachment
            detachedAttachment = nil
        } else if let attachment = device.attachment {
            detachedAttachment = attachment
            device.attachment = nil
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.onGuestStopped?() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.onStoppedWithError?(message) }
    }
}

/// Builds the real thing: a validated configuration, a framework machine, and the user-mode network stack for filtered
/// networking.
struct VZMachineFactory: MachineFactory {
    func prepare(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine {
        let built = try await ConfigurationBuilder.buildInBackground(config, bundle: bundle, display: display)
        let network = built.networkStack.map { NetworkActivity(stack: $0, policy: config.networkPolicy) }
        let suspend = Self.suspendSupport(
            of: built.configuration, allowed: suspendAllowed, filtered: config.networkMode == .filtered)
        let machine = VZVirtualMachine(configuration: built.configuration)
        return PreparedMachine(
            machine: VZGuestMachine(
                machine: machine, console: built.consoleBridge,
                networkCutoff: config.hasNetworkCutoff ? NetworkCutoff(config: config) : nil,
                startOptions: { try Self.startOptions(for: config) }),
            network: network,
            suspend: suspend
        )
    }

    private static func suspendSupport(
        of configuration: VZVirtualMachineConfiguration, allowed: Bool, filtered: Bool
    ) -> SuspendSupport {
        do {
            try configuration.validateSaveRestoreSupport()
            return allowed ? .available : .unavailable(reason: "Suspend is off for disposable or locked-down machines.")
        } catch {
            // The framework decides whether a user-mode network device can be saved; say so instead of leaving a bare error.
            return .unavailable(
                reason: filtered
                    ? "\(error.localizedDescription) Filtered networking may be the cause: switch the network to NAT to suspend."
                    : error.localizedDescription)
        }
    }

    private static func startOptions(for config: VMConfig) throws -> VZMacOSVirtualMachineStartOptions? {
        guard config.guest == .macOS else { return nil }
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
}
