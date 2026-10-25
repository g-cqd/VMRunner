import Foundation
import NetPolicy
import NetStack

enum GuestOS: String, Codable, CaseIterable, Identifiable, Sendable {
    case macOS, linux

    var id: Self { self }
    var label: String { self == .macOS ? "macOS" : "Linux" }
    var symbol: String { self == .macOS ? "apple.logo" : "terminal" }
}

enum NetworkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case nat, none
    /// Virtio NIC wired to VMRunner's own user-mode network stack, which applies `VMConfig.networkPolicy` to every connection.
    case filtered

    var id: Self { self }
    var label: String {
        switch self {
        case .nat: "NAT"
        case .none: "None"
        case .filtered: "Filtered (user-mode)"
        }
    }

    /// Whether the guest gets a network card (and so a MAC address that saved state depends on).
    var hasNetworkDevice: Bool { self != .none }
}

enum DiskCaching: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, cached, uncached

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum DiskSync: String, Codable, CaseIterable, Identifiable, Sendable {
    case full, fsync, none

    var id: Self { self }
    var label: String {
        switch self {
        case .full: "Full (safest)"
        case .fsync: "fsync"
        case .none: "None (fastest)"
        }
    }
}

/// How the machine's own disk is attached. NVMe is honoured for Linux guests only.
enum DiskInterface: String, Codable, CaseIterable, Identifiable, Sendable {
    case virtio, nvme

    var id: Self { self }
    var label: String { self == .virtio ? "Virtio" : "NVMe" }
}

enum PointingDevice: String, Codable, CaseIterable, Identifiable, Sendable {
    case trackpad, mouse

    var id: Self { self }
    var label: String { self == .trackpad ? "Trackpad" : "Mouse" }
}

struct SharedFolder: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var path: String
    var readOnly = false

    /// Name the guest sees for this directory.
    var name: String { URL(filePath: path).lastPathComponent }
}

struct ExtraDisk: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var path: String
    var readOnly = false
}

/// First-boot account setup (macOS 27 guests). The password is deliberately not persisted.
struct Provisioning: Codable, Hashable, Sendable {
    var enabled = false
    var fullName = "Admin"
    var username = "admin"
    var logsInAutomatically = true
    var enablesRemoteLogin = true
    var password = ""

    private enum CodingKeys: String, CodingKey {
        case enabled, fullName, username, logsInAutomatically, enablesRemoteLogin
    }
}

struct VMConfig: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var guest: GuestOS
    /// What the machine runs. A container machine has no disk, firmware state or display: only `container` below matters to it,
    /// and the settings of a virtual machine stay at their defaults.
    var workload = WorkloadKind.vm
    /// A container machine's image, command, environment and limits. A virtual machine ignores it.
    var container: ContainerSpec?

    // Lifecycle
    var source: ImageSource?
    var isProvisioned = false
    var hasBooted = false
    var guestVersion: String?

    // Compute
    var cpuCount: Int
    var memoryMiB: Int
    var nestedVirtualization = false

    // Storage
    var diskGiB: Int
    var diskCaching = DiskCaching.automatic
    var diskSync = DiskSync.full
    /// Linux only: how the machine's own disk is attached. NVMe shows the guest no virtio storage device.
    var diskInterface = DiskInterface.virtio
    /// The serial number the virtio disk reports to the guest, at most `EditorLimits.maxDiskSerialLength` ASCII
    /// characters; empty reports none.
    var diskSerial = ""
    var extraDisks: [ExtraDisk] = []
    var installerISO: String?
    var installerAttached = true
    /// The installer image the machine boots with attached as a read-only USB drive: Linux guests only, and only while
    /// attached. The guest can read the whole file, so this is a host channel like a shared folder.
    var attachedInstallerPath: String? { guest == .linux && installerAttached ? installerISO : nil }

    // Display
    var displayWidth = 1920
    var displayHeight = 1200
    var pixelsPerInch = 144
    /// Size the guest display to the window at start (1 guest pixel per point at 1×) instead of `displayWidth × displayHeight`.
    var fitsWindowAtStart = true
    /// The user picked "Custom" in the resolution list (as opposed to a preset or "Match window").
    var usesCustomDisplaySize = false
    /// Linux only: guest pixels per window point when the display follows the window. 1 keeps text legible.
    var pixelsPerPoint = 1
    /// Framebuffer size of the last cold boot. Saved state only restores into an identical configuration.
    var lastDisplayWidth: Int?
    var lastDisplayHeight: Int?

    // Input
    var pointingDevice = PointingDevice.trackpad
    var capturesSystemKeys = true
    var automaticallyReconfiguresDisplay = true

    // Audio
    var audioOutput = true
    var audioInput = false

    // Network
    var networkMode = NetworkMode.nat
    var macAddress: String?
    /// Whose prefix an address VMRunner makes for this machine carries. A stored address is kept as it is.
    var macVendor = MACVendor.locallyAdministered
    /// Rules for `.filtered` networking; kept (and ignored) in the other modes so switching back loses nothing. Its VPN rule
    /// (`vpn`) is the kill switch's, and applies in every mode with a network card.
    var networkPolicy = NetworkPolicy()
    /// `.filtered` only: what the guest sees when a TCP connection is denied. Fixed when the machine starts.
    var networkDenyAction = DenyAction.reset
    /// `.filtered` only: reset open connections when the Mac changes network (Wi-Fi to Ethernet, a VPN connects), so the guest
    /// reconnects over the new path instead of stalling. Fixed when the machine starts.
    var networkResetsOnHostChange = true
    /// Kill switch: disconnect the network card while the Mac's connection is metered or in Low Data Mode. Fixed when the
    /// machine starts.
    var networkCutsOnMeteredPath = false

    // Sharing
    var sharedFolders: [SharedFolder] = []
    var sharesClipboard = true
    var rosetta = false
    /// Facts about this Mac the guest can read from a read-only share; nothing by default.
    var hostInfo = HostInfoSharing()

    // Devices
    var memoryBalloon = true
    var entropyDevice = true
    var socketDevice = true
    /// Linux only: the guest's first serial port (`hvc0`) is reachable from this Mac as a local socket. A host-to-guest control
    /// channel, off by default and off in the Isolated and Hardened profiles.
    var serialConsole = false

    // Automation
    /// Scripts and AI agents holding a control token may list this machine, read its state, and start and stop it through the
    /// app's local control service (ADR-0056). Off by default, and off in the Isolated and Hardened profiles.
    var agentAccess = false

    // Provisioning
    /// Linux only: the absolute path of a provisioning spec on this Mac (ADR-0012); empty means none. The spec and the script
    /// files it names are read and compiled into a cloud-init seed at each start, not when the path is chosen.
    var provisioningSpecPath = ""
    /// The spec the next start compiles into a seed: a Linux guest's, and only while its installer is not attached, since an
    /// installer's live system would find the seed and run its steps too.
    var activeProvisioningSpecPath: String? {
        guest == .linux && attachedInstallerPath == nil && !provisioningSpecPath.isEmpty ? provisioningSpecPath : nil
    }

    // Isolation
    /// Boot from copy-on-write clones of the disk and firmware state, and discard them on stop.
    var ephemeral = false
    /// Disposable machines only: a new MAC address and machine identifier at each start, so runs can't be matched by them.
    var freshIdentityPerStart = false
    /// Suspending writes guest memory to disk, so locked-down machines turn it off.
    var allowsSuspend = true
    /// Shut the machine down after this many minutes; 0 means no limit.
    var maxRuntimeMinutes = 0
    /// Linux only (macOS 27+): enforce UEFI Secure Boot with the Apple platform key and Microsoft's keys.
    var secureBoot = false
    /// Linux only: whether the catalog image the machine was made from has a signed boot chain, so Secure Boot can be on. True
    /// for every other source, including a file the user picked, whose capability is unknown, and for a machine stored before
    /// this existed. Setup records it from the catalog entry (`recordCatalogImageCapabilities()`).
    var imageSupportsSecureBoot = true

    // Boot
    var bootIntoRecovery = false
    var provisioning = Provisioning()

    static func new(name: String, guest: GuestOS) -> Self {
        let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
        let hostMemoryGiB = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        var config = Self(
            name: name,
            guest: guest,
            cpuCount: max(2, min(4, hostCPUs / 2)),
            memoryMiB: min(guest == .macOS ? 8 : 4, max(2, hostMemoryGiB / 2)) * 1024,
            diskGiB: guest == .macOS ? 100 : 64
        )
        if guest == .linux {
            config.pointingDevice = .mouse
            config.displayWidth = 1280
            config.displayHeight = 800
        }
        return config
    }

    /// A container machine. Its settings are a Linux guest's, it has nothing to set up, and a spec left out is the default one.
    static func newContainer(name: String, container: ContainerSpec = ContainerSpec()) -> Self {
        var config = Self.new(name: name, guest: .linux)
        config.workload = .container
        config.container = container
        config.isProvisioned = true
        return config
    }
}

extension VMConfig {
    /// Decodes a stored config, filling any key added since it was written with its default value.
    ///
    /// The data is untrusted: it is refused when too large or too deeply nested, and the decoded values are refused when
    /// they fall outside the ranges the editor offers (`validate()`).
    static func decode(from data: Data) throws -> VMConfig {
        try checkBounds(of: data)
        guard let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a JSON object"))
        }
        let guest = (stored["guest"] as? String).flatMap(GuestOS.init(rawValue:)) ?? .linux
        let defaults = try JSONSerialization.jsonObject(with: Self.new(name: "", guest: guest).encoded()) as? [String: Any] ?? [:]
        let merged = overlay(stored, on: defaults)
        // A number the parser read as infinite or NaN can't be written back, and writing it raises an exception.
        guard JSONSerialization.isValidJSONObject(merged) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The configuration holds a number out of range"))
        }
        var config = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: merged))
        // A container machine always has a spec: one stored without any key of it runs the default container.
        if config.workload == .container, config.container == nil { config.container = ContainerSpec() }
        try config.validate()
        return config
    }

    private static func overlay(_ top: [String: Any], on base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in top {
            if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
                result[key] = overlay(nested, on: baseNested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension VMConfig {
    /// Whether a memory image saved by a machine with the `previous` configuration can be restored into one built from this
    /// one. It compares the Secure Boot setting (its firmware variable store is not comparable here), the network device
    /// (NAT, none or the user-mode stack), the disk as the machine builds it (see `effectiveDisk`), and whether the
    /// host-information share is present (an extra file-system device while anything is shared), and the provisioning spec
    /// in use (its seed is a read-only virtio disk; `ProvisioningSeed.prepare` also drops a saved state whose seed's contents changed).
    /// Other hardware changes make the restore fail, and the machine then cold boots with an error message.
    func restoresSavedState(of previous: Self) -> Bool {
        secureBoot == previous.secureBoot && networkMode == previous.networkMode && effectiveDisk == previous.effectiveDisk
            && hostInfo.isEmpty == previous.hostInfo.isEmpty && activeProvisioningSpecPath == previous.activeProvisioningSpecPath
    }

    /// The disk as the machine builds it: an NVMe drive only for a Linux guest, and a serial number only on a virtio disk.
    private var effectiveDisk: (nvme: Bool, serial: String) {
        let nvme = guest == .linux && diskInterface == .nvme
        return (nvme, nvme ? "" : diskSerial)
    }
}

struct DisplayPreset: Identifiable, Hashable, Sendable {
    var width: Int
    var height: Int

    var id: String { "\(width)x\(height)" }
    var aspect: String { width * 9 == height * 16 ? "16:9" : width * 10 == height * 16 ? "16:10" : "\(width):\(height)" }
    var label: String { "\(width) × \(height) (\(aspect))" }

    static let all = [
        Self(width: 1280, height: 800), Self(width: 1440, height: 900),
        Self(width: 1680, height: 1050), Self(width: 1920, height: 1200),
        Self(width: 2560, height: 1600), Self(width: 1280, height: 720),
        Self(width: 1920, height: 1080), Self(width: 2560, height: 1440),
    ]
}
