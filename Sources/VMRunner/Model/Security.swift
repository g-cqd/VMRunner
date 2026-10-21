import Foundation

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
            "Contained, plus no network, no shared folders, extra disks or attached installer, no sound, "
                + "and Secure Boot on Linux when the host runs macOS 27 or later."
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
}

extension VMConfig {
    func applying(_ profile: SecurityProfile) -> VMConfig {
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
        config.audioOutput = false
        config.sharedFolders = []
        config.extraDisks = []
        config.installerAttached = false
        config.secureBoot = guest == .linux && HostCapabilities.secureBoot
        guard profile == .hardened else { return config }

        config.ephemeral = true
        config.allowsSuspend = false
        config.maxRuntimeMinutes = 120
        config.memoryBalloon = false
        config.provisioning.logsInAutomatically = false
        config.provisioning.enablesRemoteLogin = false
        return config
    }

    /// The profile whose settings this machine currently matches, or nil when customized.
    var detectedProfile: SecurityProfile? {
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
        var balloon: Bool
        var ephemeral: Bool
        var suspend: Bool
        var maxRuntime: Int
        var secureBoot: Bool
        var recovery: Bool
        var autoLogin: Bool
        var remoteLogin: Bool
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
            installer: attachedInstallerPath != nil,
            clipboard: linux && sharesClipboard,
            microphone: audioInput,
            speakers: audioOutput,
            rosetta: linux && rosetta,
            nested: linux && nestedVirtualization,
            vsock: socketDevice,
            balloon: memoryBalloon,
            ephemeral: ephemeral,
            suspend: allowsSuspend,
            maxRuntime: maxRuntimeMinutes,
            secureBoot: linux && secureBoot,
            recovery: guest == .macOS && bootIntoRecovery,
            autoLogin: provisioned && provisioning.logsInAutomatically,
            remoteLogin: provisioned && provisioning.enablesRemoteLogin
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
        var items: [Exposure] = []
        switch networkMode {
        case .nat:
            items.append(
                Exposure(level: .medium, text: "Network: the guest can reach the internet and, through the host, your local network."))
        case .none: items.append(Exposure(level: .none, text: "Network: none."))
        case .filtered: items += filteredNetworkExposures
        }
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
        if guest == .linux, sharesClipboard { items.append(Exposure(level: .medium, text: "Clipboard is shared with the host.")) }
        if audioInput { items.append(Exposure(level: .medium, text: "The guest can record from the microphone.")) }
        if audioOutput { items.append(Exposure(level: .low, text: "The guest can play sound.")) }
        if guest == .linux, rosetta {
            items.append(Exposure(level: .low, text: "Rosetta share: exposes a host translation runtime to the guest."))
        }
        if guest == .linux, nestedVirtualization {
            items.append(Exposure(level: .medium, text: "Nested virtualization: the guest can run its own hypervisor."))
        }
        if socketDevice { items.append(Exposure(level: .low, text: "vsock: a host–guest socket channel is present.")) }
        if memoryBalloon { items.append(Exposure(level: .low, text: "Memory balloon device present.")) }
        items.append(
            allowsSuspend && !ephemeral
                ? Exposure(level: .medium, text: "Suspending writes the guest's memory, including secrets, unencrypted to disk.")
                : Exposure(level: .none, text: "No memory snapshot is written to disk."))
        items.append(
            ephemeral
                ? Exposure(level: .none, text: "Disposable: disk and firmware changes are discarded when the VM stops.")
                : Exposure(level: .low, text: "Persistent: anything the guest writes, including malware, stays in the disk image."))
        if guest == .linux {
            items.append(
                secureBoot
                    ? Exposure(level: .none, text: "Secure Boot is enforced.")
                    : Exposure(level: .low, text: "Secure Boot is off: unsigned bootloaders and kernels can run."))
        }
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
