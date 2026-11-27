import Foundation
import GuestConsole
import Virtualization
import os

/// A `VZVirtualMachine` behind the controller's seam. It is also the machine's delegate, and forwards the callbacks that
/// arrive on the framework's queue to the main actor.
@MainActor
final class VZGuestMachine: NSObject, GuestMachine, VZVirtualMachineDelegate {
    let machine: VZVirtualMachine
    /// The machine's custom GPU, when it has one. The framework holds the device it makes weakly, so this is what keeps the
    /// device alive: it lives and ends with this object.
    let customDisplay: (any CustomDisplaySource)?
    /// Serves the guest's serial console on a local socket. It starts with the machine and ends when this object is released
    /// (or earlier, when the guest side of the port closes), so the socket exists exactly while the machine can use it.
    private let console: ConsoleBridge?
    /// Evaluated at start, not at creation: a restore never needs them, and a bad provisioning setup must fail the start.
    private let startOptions: () throws -> VZMacOSVirtualMachineStartOptions?
    /// The kill switch of this run, when the machine has a VPN or metered-network rule. It starts with the machine and
    /// ends when this object is released.
    let networkCutoff: NetworkCutoff?
    /// The network card's cable as the kill switch pulls it, with the attachment it took off to put back.
    private var cable = NetworkCardCable()
    /// Set once the kill switch has stopped the machine for a refused cut, so the stop is requested once.
    private var isStoppingForCut = false
    /// What the machine's stop says when the kill switch could not disconnect its network card.
    static let cutFailedMessage = "the kill switch could not disconnect its network card, so VMRunner stopped it"
    /// Keeps the host-information share current while the machine lives, when the machine shares anything.
    private let hostInfo: HostInfoPublisher?
    /// The guest vsock ports to serve on local sockets, and where; served from the start until the machine stops.
    private let vsockForwards: [(port: UInt32, placement: VsockForwardPlacement)]
    /// The forwarders serving `vsockForwards` now.
    private var forwarders: [PortForwarder] = []

    var onGuestStopped: (@MainActor () -> Void)?
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)?

    init(
        machine: VZVirtualMachine, customDisplay: (any CustomDisplaySource)? = nil, console: ConsoleBridge? = nil,
        networkCutoff: NetworkCutoff? = nil, hostInfo: HostInfoPublisher? = nil,
        vsockForwards: [(port: UInt32, placement: VsockForwardPlacement)] = [],
        startOptions: @escaping () throws -> VZMacOSVirtualMachineStartOptions?
    ) {
        self.machine = machine
        self.customDisplay = customDisplay
        self.console = console
        self.networkCutoff = networkCutoff
        self.hostInfo = hostInfo
        self.vsockForwards = vsockForwards
        self.startOptions = startOptions
        super.init()
        machine.delegate = self
        customDisplay?.input.use(machine: machine)
    }

    var capabilities: WorkloadCapabilities { .virtualMachine }
    var virtualMachine: VZVirtualMachine? { machine }
    var canStop: Bool { machine.canStop }

    func start() async throws {
        hostInfo?.start()
        console?.start()
        if let options = try startOptions() {
            try await machine.start(options: options)
        } else {
            try await machine.start()
        }
        customDisplay?.beginDisplay(for: machine) { [weak self] message in self?.onStoppedWithError?(message) }
        startNetworkCutoff()
        startForwarders()
    }

    func restoreState(from url: URL) async throws {
        hostInfo?.start()
        console?.start()
        try await machine.restoreMachineStateFrom(url: url)
        startNetworkCutoff()
        startForwarders()
    }
    func saveState(to url: URL) async throws { try await machine.saveMachineStateTo(url: url) }
    func pause() async throws { try await machine.pause() }
    func resume() async throws { try await machine.resume() }
    func requestStop() throws { try machine.requestStop() }
    func stop() async throws {
        try await machine.stop()
        customDisplay?.endDisplay()
        stopForwarders()
    }

    // MARK: Vsock forwards

    /// Serves each forwarded port on its socket. A port that cannot be served is logged and skipped: the machine runs
    /// without that channel rather than not at all.
    private func startForwarders() {
        guard forwarders.isEmpty, !vsockForwards.isEmpty, machine.socketDevices.first is VZVirtioSocketDevice else { return }
        for (port, placement) in vsockForwards {
            do {
                try ConsoleBridge.makePrivateDirectory(at: placement.directory)
                let forwarder = try PortForwarder(socketPath: placement.path) { [weak self] in
                    await self?.openVsock(port: port)
                }
                forwarder.start()
                forwarders.append(forwarder)
                Log.machine.info("Forwarding guest vsock port \(port, privacy: .public) on a local socket")
            } catch {
                Log.machine.error(
                    "Cannot forward guest vsock port \(port, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopForwarders() {
        for forwarder in forwarders { forwarder.stop() }
        forwarders = []
    }

    /// A new connection to guest vsock `port`, or nil when the guest does not accept it. The framework's connection object
    /// owns its descriptor, so the forwarder gets a duplicate, and the object is kept and closed when the relay is done.
    private func openVsock(port: UInt32) async -> PortForwarder.Channel? {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else { return nil }
        do {
            let connection = try await device.connect(toPort: port)
            let descriptor = dup(connection.fileDescriptor)
            guard descriptor >= 0 else {
                connection.close()
                return nil
            }
            let owner = VsockConnectionOwner(connection)
            return PortForwarder.Channel(descriptor: descriptor) { owner.close() }
        } catch {
            return nil
        }
    }

    /// Starts the kill switch once the framework has the machine, so its network card can be reached.
    private func startNetworkCutoff() {
        networkCutoff?.start { [weak self] connected in self?.setNetworkConnected(connected) }
    }

    /// Takes the attachment off the network card (`false`) or puts the one it had back (`true`), like pulling and
    /// replugging a cable. A pull is read back at once: a card that is still connected stops the machine. The kill switch
    /// logs each cut and reconnection with its reason (`NetworkCutoff.logLine`). This object does not implement the
    /// delegate's `virtualMachine(_:networkDevice:attachmentWasDisconnectedWithError:)`, which the framework calls when an
    /// error disconnects an attachment: such a disconnection is neither logged nor shown, and the kill switch does not see it.
    private func setNetworkConnected(_ connected: Bool) {
        guard let device = machine.networkDevices.first else { return }
        if !cable.set(device, connected: connected) { stopBecauseTheCutFailed() }
    }

    /// Fails closed when the network card kept its attachment after the kill switch took it off: the guest must not keep
    /// running behind a toolbar that says its network is cut. Stopping is the default until the owner decides between
    /// stopping and only showing an error (roadmap 0010, "Owed"). A refused cut is stopped once, however often it is refused.
    private func stopBecauseTheCutFailed() {
        guard !isStoppingForCut else { return }
        isStoppingForCut = true
        Log.machine.error("The network card stayed connected after the kill switch cut it; stopping the machine")
        Task { [weak self, machine] in
            var message = Self.cutFailedMessage
            do { try await machine.stop() } catch { message += "; stopping it failed (\(error.localizedDescription))" }
            self?.onStoppedWithError?(message)
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            self.stopForwarders()
            self.customDisplay?.endDisplay()
            self.onGuestStopped?()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.stopForwarders()
            self.customDisplay?.endDisplay()
            self.onStoppedWithError?(message)
        }
    }
}

/// Keeps a framework vsock connection, which owns its descriptor, until the relay that uses a duplicate is done, then
/// closes it on the main actor.
private final class VsockConnectionOwner: @unchecked Sendable {  // `connection` is only touched on the main actor
    private let connection: VZVirtioSocketConnection

    init(_ connection: VZVirtioSocketConnection) { self.connection = connection }

    func close() {
        Task { @MainActor in self.connection.close() }
    }
}

/// Builds the real thing: a validated configuration, a framework machine, and the user-mode network stack for filtered
/// networking.
struct VZMachineFactory: MachineFactory {
    func prepare(
        _ requested: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine {
        // A key forced after the library loaded still applies: the configuration is clamped once, here, and everything below
        // (the custom GPU, the suspend reason, the network) uses the clamped copy.
        let config = Self.effective(requested, policy: ManagedPreferences.current)
        // The seed is built from the spec and its scripts as they are now, before the configuration that attaches it; a spec
        // that cannot be used stops the start with its line. The disposable copy, which clears the run's leftovers, is made before.
        // The configuration is clamped again here: a managed key that arrived after the library loaded still blocks the seed.
        try await ProvisioningSeed.prepare(for: ManagedPreferences.current.clamp(config), bundle: bundle)
        // The custom GPU is made here, on the main actor, and handed to the machine, which keeps it for as long as it lives.
        // The path of its keyboard and pointer is read once, now.
        let customGPU: (any CustomDisplaySource)?
        let windowsBoot: WindowsBootMedia?
        if config.guest == .windows {
            guard #available(macOS 27.0, *) else {
                throw SetupError.requiredCapabilityUnavailable(
                    guest: .windows, capability: "framebuffer-assisted boot", reason: "macOS 27 or later is required")
            }
            let media = try await WindowsBootMedia.prepare(in: bundle)
            windowsBoot = media
            customGPU = WindowsDisplaySession(variables: media.variables, token: media.token)
        } else {
            windowsBoot = nil
            customGPU = Self.customGPU(for: config, display: display, inputPath: CustomGPUInputPath.current())
        }
        // A Windows machine's private interface is decided now, once, the way the custom GPU's input path is.
        var windows = config.guest == .windows ? WindowsStartSettings.current(for: config) : nil
        windows?.bootMedia = windowsBoot
        let built = try await ConfigurationBuilder.buildInBackground(
            config, bundle: bundle, display: display, customGPU: customGPU, windows: windows)
        let network = built.networkStack.map { NetworkActivity(stack: $0, policy: config.networkPolicy) }
        let suspend =
            (config.guestSuspendReason ?? config.customGPUSuspendReason()).map { SuspendSupport.unavailable(reason: $0) }
            ?? Self.suspendSupport(of: built.configuration, allowed: suspendAllowed, filtered: config.networkMode == .filtered)
        let machine = VZVirtualMachine(configuration: built.configuration)
        return PreparedMachine(
            machine: VZGuestMachine(
                machine: machine, customDisplay: customGPU, console: built.consoleBridge,
                networkCutoff: config.hasNetworkCutoff ? NetworkCutoff(config: config) : nil,
                hostInfo: config.hostInfo.isEmpty ? nil : HostInfoPublisher(directory: bundle.hostInfoFolder, sharing: config.hostInfo),
                vsockForwards: config.socketDevice ? config.vsockForwards.map { ($0, bundle.vsockForward(port: $0)) } : [],
                startOptions: { try Self.startOptions(for: config) }),
            network: network,
            suspend: suspend
        )
    }

    /// The configuration a start uses: the one stored, with the managed keys of `policy` applied to it.
    static func effective(_ config: VMConfig, policy: ManagedPreferences) -> VMConfig {
        policy.clamp(config)
    }

    /// The custom GPU of a machine set to use it, or `nil` for any other machine and on a host that cannot build the device
    /// (the builder then refuses the machine with a message).
    private static func customGPU(
        for config: VMConfig, display: (width: Int, height: Int), inputPath: CustomGPUInputPath
    ) -> (any CustomDisplaySource)? {
        guard config.usesCustomGPU, #available(macOS 27.0, *) else { return nil }
        return CustomGPUSession(display: display, input: inputPath.makeSurface())
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
