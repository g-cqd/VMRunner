import Foundation
import Virtualization

/// A `VZVirtualMachine` behind the controller's seam. It is also the machine's delegate, and forwards the callbacks that
/// arrive on the framework's queue to the main actor.
@MainActor
final class VZGuestMachine: NSObject, GuestMachine, VZVirtualMachineDelegate {
    let machine: VZVirtualMachine
    /// Evaluated at start, not at creation: a restore never needs them, and a bad provisioning setup must fail the start.
    private let startOptions: () throws -> VZMacOSVirtualMachineStartOptions?

    var onGuestStopped: (@MainActor () -> Void)?
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)?

    init(machine: VZVirtualMachine, startOptions: @escaping () throws -> VZMacOSVirtualMachineStartOptions?) {
        self.machine = machine
        self.startOptions = startOptions
        super.init()
        machine.delegate = self
    }

    var virtualMachine: VZVirtualMachine? { machine }
    var canStop: Bool { machine.canStop }

    func start() async throws {
        if let options = try startOptions() {
            try await machine.start(options: options)
        } else {
            try await machine.start()
        }
    }

    func restoreState(from url: URL) async throws { try await machine.restoreMachineStateFrom(url: url) }
    func saveState(to url: URL) async throws { try await machine.saveMachineStateTo(url: url) }
    func pause() async throws { try await machine.pause() }
    func resume() async throws { try await machine.resume() }
    func requestStop() throws { try machine.requestStop() }
    func stop() async throws { try await machine.stop() }

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
    ) throws -> PreparedMachine {
        let built = try ConfigurationBuilder.build(config, bundle: bundle, display: display)
        let network = built.networkStack.map { NetworkActivity(stack: $0, policy: config.networkPolicy) }
        let suspend = Self.suspendSupport(
            of: built.configuration, allowed: suspendAllowed, filtered: config.networkMode == .filtered)
        let machine = VZVirtualMachine(configuration: built.configuration)
        return PreparedMachine(
            machine: VZGuestMachine(machine: machine, startOptions: { try Self.startOptions(for: config) }),
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
