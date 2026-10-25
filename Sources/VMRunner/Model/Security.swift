import Foundation
import NetPolicy

/// One-tap starting points for how much of the host a guest can reach. Each profile only sets what it
/// defines; per-device switches stay editable afterwards.
enum SecurityProfile: String, CaseIterable, Identifiable, Sendable {
    case standard, contained, isolated, hardened

    var id: Self { self }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .contained: "Contained"
        case .isolated: "Isolated"
        case .hardened: "Hardened"
        }
    }

    var summary: String {
        switch self {
        case .standard:
            "Everyday use: NAT network, clipboard, sound, and any folders you share."
        case .contained:
            "Keeps the network, but cuts host channels: no clipboard, microphone, Rosetta, nested virtualization, or vsock; "
                + "shared folders become read-only."
        case .isolated:
            "Contained, plus no network, no shared folders, extra disks, attached installer or driver disc, or host information, "
                + "no sound, and Secure Boot on Linux when the host runs macOS 27 or later and the image can boot with it."
        case .hardened:
            "Isolated, plus a disposable disk (changes are discarded on stop), no suspend files, no memory balloon, "
                + "no first-boot auto-login or SSH, and a 2-hour runtime limit."
        }
    }
}

enum HostCapabilities {
    /// Secure Boot management in the EFI variable store arrived in macOS 27.
    static var secureBoot: Bool {
        if #available(macOS 27.0, *) { true } else { false }
    }

    /// The host-implemented virtio GPU needs the custom device support that arrived in macOS 27.
    static var customGPU: Bool {
        if #available(macOS 27.0, *) { true } else { false }
    }
}

/// Whether Secure Boot can be on for a machine, and if not, why: the host and the machine's image must both be able to use it.
enum SecureBootAvailability: Equatable, Sendable {
    /// A guest that has no Secure Boot switch.
    case notApplicable
    case available
    case hostTooOld
    /// The image this machine was made from has an unsigned boot chain, so it would not start with Secure Boot on.
    case imageUnsupported

    /// What the editor says under the switch.
    var note: String {
        switch self {
        case .notApplicable: ""
        case .available: "Only signed bootloaders and kernels run. CentOS, RHEL, Fedora, Ubuntu, and Debian ship signed ones."
        case .hostTooOld: "Needs macOS 27 or later."
        case .imageUnsupported:
            "The image this machine was made from has no signed bootloader and can't start with Secure Boot, "
                + "so it stays off and no security profile turns it on."
        }
    }
}

extension VMConfig {
    /// `hostSupports` is a parameter so tests can cover a host that manages Secure Boot as well as one that does not.
    func secureBootAvailability(hostSupports: Bool = HostCapabilities.secureBoot) -> SecureBootAvailability {
        guard guest == .linux else { return .notApplicable }
        guard imageSupportsSecureBoot else { return .imageUnsupported }
        return hostSupports ? .available : .hostTooOld
    }

    /// Whether the Secure Boot switch can be changed. A machine whose image cannot use Secure Boot can only have it turned off.
    var secureBootIsEditable: Bool {
        switch secureBootAvailability() {
        case .available: true
        case .imageUnsupported: secureBoot
        case .hostTooOld, .notApplicable: false
        }
    }

    /// The note under the switch; says what to do when the switch is on although the image cannot start with it.
    var secureBootNote: String {
        let availability = secureBootAvailability()
        guard availability == .imageUnsupported, secureBoot else { return availability.note }
        return availability.note + " Turn it off, or the machine will not start."
    }

    /// Records what the catalog image this machine installs from can do. Setup calls it once the machine's media is chosen;
    /// any other source, a file the user picked included, is of unknown capability and keeps the default.
    mutating func recordCatalogImageCapabilities() {
        guard case .linuxCatalog(let id) = source, let image = LinuxCatalog.image(id: id) else { return }
        imageSupportsSecureBoot = image.supportsSecureBoot
    }

    /// A container machine takes no profile: the profiles set virtual machine channels it does not have, so it comes back as it was.
    func applying(_ profile: SecurityProfile, hostSupportsSecureBoot: Bool = HostCapabilities.secureBoot) -> VMConfig {
        guard workload == .vm else { return self }
        var config = self
        // Standard restores the channels the stricter profiles close; it leaves your own opt-ins alone.
        config.networkMode = .nat
        config.sharesClipboard = true
        config.audioOutput = true
        config.audioInput = false
        config.socketDevice = true
        config.memoryBalloon = true
        config.ephemeral = false
        config.allowsSuspend = true
        config.maxRuntimeMinutes = 0
        config.secureBoot = false
        guard profile != .standard else { return config }

        config.sharesClipboard = false
        config.rosetta = false
        config.nestedVirtualization = false
        config.socketDevice = false
        config.bootIntoRecovery = false
        for index in config.sharedFolders.indices { config.sharedFolders[index].readOnly = true }
        for index in config.extraDisks.indices { config.extraDisks[index].readOnly = true }
        guard profile != .contained else { return config }

        config.networkMode = .none
        config.serialConsole = false
        config.agentAccess = false
        config.gpu = .apple
        config.provisioningSpecPath = ""
        config.audioOutput = false
        config.sharedFolders = []
        config.extraDisks = []
        config.installerAttached = false
        config.driverDiscPath = nil
        config.hostInfo = HostInfoSharing()
        config.secureBoot = secureBootAvailability(hostSupports: hostSupportsSecureBoot) == .available
        guard profile == .hardened else { return config }

        config.ephemeral = true
        config.allowsSuspend = false
        config.maxRuntimeMinutes = 120
        config.memoryBalloon = false
        config.provisioning.logsInAutomatically = false
        config.provisioning.enablesRemoteLogin = false
        return config
    }

    /// The profile whose settings this machine currently matches, or nil when customized. A container machine matches none:
    /// it has no `Posture`, because the profiles describe virtual machine channels.
    var detectedProfile: SecurityProfile? {
        guard workload == .vm else { return nil }
        let current = posture
        return SecurityProfile.allCases.reversed().first { applying($0).posture == current }
    }

    /// Everything a profile can change, restricted to what applies to this guest.
    struct Posture: Equatable {
        var network: NetworkMode
        var writableShares: Int
        var readOnlyShares: Int
        var writableDisks: Int
        var readOnlyDisks: Int
        var installer: Bool
        var clipboard: Bool
        var microphone: Bool
        var speakers: Bool
        var rosetta: Bool
        var nested: Bool
        var vsock: Bool
        var serialConsole: Bool
        var agentAccess: Bool
        var customGPU: Bool
        var provisioning: Bool
        var balloon: Bool
        var ephemeral: Bool
        var suspend: Bool
        var maxRuntime: Int
        var secureBoot: Bool
        var recovery: Bool
        var autoLogin: Bool
        var remoteLogin: Bool
        var hostInfo: HostInfoSharing
    }

    var posture: Posture {
        let linux = guest == .linux
        let provisioned = guest == .macOS && provisioning.enabled && !hasBooted
        return Posture(
            network: networkMode,
            writableShares: sharedFolders.filter { !$0.readOnly }.count,
            readOnlyShares: sharedFolders.filter(\.readOnly).count,
            writableDisks: extraDisks.filter { !$0.readOnly }.count,
            readOnlyDisks: extraDisks.filter(\.readOnly).count,
            installer: attachedInstallerPath != nil || attachedDriverDiscPath != nil,
            clipboard: linux && sharesClipboard,
            microphone: audioInput,
            speakers: audioOutput,
            rosetta: linux && rosetta,
            nested: guest.usesGenericPlatform && nestedVirtualization,
            vsock: socketDevice,
            serialConsole: linux && serialConsole,
            agentAccess: agentAccess,
            customGPU: usesCustomGPU,
            provisioning: linux && !provisioningSpecPath.isEmpty,
            balloon: memoryBalloon,
            ephemeral: ephemeral,
            suspend: allowsSuspend,
            maxRuntime: maxRuntimeMinutes,
            secureBoot: linux && secureBoot,
            recovery: guest == .macOS && bootIntoRecovery,
            autoLogin: provisioned && provisioning.logsInAutomatically,
            remoteLogin: provisioned && provisioning.enablesRemoteLogin,
            hostInfo: hostInfo
        )
    }
}

/// A channel between guest and host, for the exposure summary.
struct Exposure: Identifiable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case none, low, medium, high
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id = UUID()
    var level: Level
    var text: String
}

extension VMConfig {
    var exposures: [Exposure] {
        if workload == .container { return containerExposures }
        var items: [Exposure] = []
        switch networkMode {
        case .nat:
            items.append(
                Exposure(level: .medium, text: "Network: the guest can reach the internet and, through the host, your local network."))
        case .none: items.append(Exposure(level: .none, text: "Network: none."))
        case .filtered: items += filteredNetworkExposures
        }
        if networkMode.hasNetworkDevice { items += networkCutoffExposures }
        for folder in sharedFolders {
            items.append(
                folder.readOnly
                    ? Exposure(level: .medium, text: "The guest can read \(folder.path)")
                    : Exposure(level: .high, text: "The guest can read and modify \(folder.path)"))
        }
        for disk in extraDisks {
            items.append(
                disk.readOnly
                    ? Exposure(level: .low, text: "Extra disk (read-only): \(disk.path)")
                    : Exposure(level: .medium, text: "Extra disk (writable): \(disk.path)"))
        }
        if let installer = attachedInstallerPath {
            items.append(Exposure(level: .medium, text: "The guest can read the installer image \(installer) (attached read-only)."))
        }
        if let disc = attachedDriverDiscPath {
            items.append(Exposure(level: .medium, text: "The guest can read the driver disc \(disc) (attached read-only)."))
        }
        if let spec = activeProvisioningSpecPath {
            // The guest reads the whole seed and runs its steps as root: the spec's text and its scripts reach it.
            items.append(
                Exposure(
                    level: .medium,
                    text: "Provisioning (experimental): at each start the guest reads a seed built from \(spec) and runs its "
                        + "steps as root."))
        }
        if guest == .linux, sharesClipboard { items.append(Exposure(level: .medium, text: "Clipboard is shared with the host.")) }
        if !hostInfo.isEmpty {
            let shared = hostInfo.names.joined(separator: ", ")
            items.append(Exposure(level: .low, text: "The guest can read this Mac's \(shared) (read-only share)."))
        }
        if audioInput { items.append(Exposure(level: .medium, text: "The guest can record from the microphone.")) }
        if audioOutput { items.append(Exposure(level: .low, text: "The guest can play sound.")) }
        if guest == .linux, rosetta {
            items.append(Exposure(level: .low, text: "Rosetta share: exposes a host translation runtime to the guest."))
        }
        if guest.usesGenericPlatform, nestedVirtualization {
            items.append(Exposure(level: .medium, text: "Nested virtualization: the guest can run its own hypervisor."))
        }
        if socketDevice { items.append(Exposure(level: .low, text: "vsock: a host–guest socket channel is present.")) }
        if guest == .linux, serialConsole {
            // Any process of this user can type into the guest through the socket, so it ranks with a shared folder.
            let path = VMBundle(id: id, in: AppPaths.machines).consoleSocket().path
            items.append(Exposure(level: .medium, text: "A serial console is reachable from this Mac as a local socket at \(path)"))
        }
        if agentAccess { items.append(agentAccessExposure) }
        if usesCustomGPU {
            // The guest's commands to its graphics device are parsed by this app, inside its own process.
            items.append(Exposure(level: .medium, text: "Custom GPU: the app parses the guest's graphics commands itself."))
        }
        items += privateCapabilities.map(PrivateCapabilityPolicy.exposure(for:))
        if memoryBalloon { items.append(Exposure(level: .low, text: "Memory balloon device present.")) }
        items.append(
            allowsSuspend && !ephemeral && !usesCustomGPU && guestSuspendReason == nil
                ? Exposure(level: .medium, text: "Suspending writes the guest's memory, including secrets, unencrypted to disk.")
                : Exposure(level: .none, text: "No memory snapshot is written to disk."))
        items.append(
            ephemeral
                ? Exposure(level: .none, text: "Disposable: disk and firmware changes are discarded when the VM stops.")
                : Exposure(level: .low, text: "Persistent: anything the guest writes, including malware, stays in the disk image."))
        if guest.usesGenericPlatform { items.append(secureBootExposure) }
        if guest == .macOS, provisioning.enabled, !hasBooted {
            if provisioning.logsInAutomatically {
                items.append(Exposure(level: .medium, text: "The first-boot account logs in automatically."))
            }
            if provisioning.enablesRemoteLogin {
                items.append(Exposure(level: .medium, text: "Remote Login (SSH) is enabled in the guest."))
            }
        }
        return items
    }
}

extension VMConfig {
    /// A host-side door: it starts and stops the machine; the one thing it reads of the guest is the picture of a custom GPU's
    /// screen.
    var agentAccessExposure: Exposure {
        Exposure(
            level: .low,
            text: "Agent access: a script or AI agent with a control token can see this machine and start or stop it "
                + "while the control service is on in Settings. A token with the Read screen capability can also read the picture "
                + "of the screen of a machine that uses the custom GPU.")
    }

    fileprivate var secureBootExposure: Exposure {
        let unusable = secureBootAvailability() == .imageUnsupported
        if secureBoot {
            return unusable
                ? Exposure(level: .low, text: "Secure Boot is on, but this machine's image has no signed bootloader, so it will not start.")
                : Exposure(level: .none, text: "Secure Boot is enforced.")
        }
        return unusable
            ? Exposure(
                level: .low,
                text: "Secure Boot is off and stays off: this machine's image has no signed bootloader, so no profile can turn it on. "
                    + "Unsigned bootloaders and kernels can run.")
            : Exposure(level: .low, text: "Secure Boot is off: unsigned bootloaders and kernels can run.")
    }

    /// The kill switch closes rather than opens, so its lines are level `.none`: they say what it watches.
    fileprivate var networkCutoffExposures: [Exposure] {
        var items: [Exposure] = []
        switch networkPolicy.vpn {
        case .required:
            items.append(Exposure(level: .none, text: "Kill switch: the network is cut while no VPN is up on this Mac."))
        case .forbidden:
            items.append(Exposure(level: .none, text: "Kill switch: the network is cut while a VPN is up on this Mac."))
        case .ignore:
            break
        }
        if networkCutsOnMeteredPath {
            items.append(
                Exposure(level: .none, text: "The network is cut while this Mac's connection is metered or in Low Data Mode."))
        }
        return items
    }

    /// Filtered networking narrows reach, but it is a young implementation that sits in this app's own process, so the
    /// summary says what it enforces, what it can't, and that the guest's frames are parsed by VMRunner itself.
    fileprivate var filteredNetworkExposures: [Exposure] {
        var items: [Exposure] = []
        if networkPolicy.mode == .allowListed {
            items.append(
                Exposure(
                    level: .low,
                    text: "Network (filtered): the guest can reach only destinations your allow-list names, over IPv4, and "
                        + "can look up only the names your allow-list names."))
        } else if networkPolicy.blockPrivateRanges {
            items.append(
                Exposure(
                    level: .medium,
                    text: "Network (filtered): the guest can reach the internet over IPv4. Your Mac, your local network "
                        + "and other private ranges are blocked."))
        } else {
            items.append(
                Exposure(
                    level: .medium,
                    text: "Network (filtered): the guest can reach the internet and, through your Mac, your local network "
                        + "(private ranges are not blocked). Only your block rules apply, except that your Mac's own "
                        + "addresses (loopback, link-local, the virtual network) stay blocked."))
        }
        if networkPolicy.usesDomainRules {
            items.append(
                Exposure(
                    level: .low,
                    text: "Domain rules are advisory: encrypted DNS (DoH, DoT) and servers that share an address can get "
                        + "around them. Use address rules where it matters."))
        }
        items.append(
            Exposure(
                level: .low,
                text: "Filtered networking is implemented by VMRunner itself, not by macOS: the guest's network frames are "
                    + "parsed inside this app, and the implementation has not been validated against every guest."))
        return items
    }
}
