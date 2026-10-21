import Foundation
import Virtualization

/// Translates a `VMConfig` plus its on-disk bundle into a validated `VZVirtualMachineConfiguration`.
enum ConfigurationBuilder {
    /// Tag that makes macOS guests mount shared folders under /Volumes/My Shared Files automatically.
    static let linuxShareTag = "share"
    static let rosettaTag = "rosetta"

    static var cpuRange: ClosedRange<Int> {
        VZVirtualMachineConfiguration.minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }

    static var memoryRangeMiB: ClosedRange<Int> {
        Int(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize >> 20)...Int(
                VZVirtualMachineConfiguration.maximumAllowedMemorySize >> 20)
    }

    /// Widest framebuffer a Linux guest is started with. UEFI and GRUB draw fixed-size glyphs, so on a
    /// large window a framebuffer that matches it pixel for pixel makes their text tiny. A capped one with
    /// the window's aspect ratio is scaled up by the view instead; the guest OS then follows the window.
    static let legibleStartWidth = 1280

    /// Guest framebuffer size in pixels for this boot.
    ///
    /// With `fitsWindowAtStart` the guest gets the window's aspect ratio at `displayScale` pixels per point,
    /// capped for Linux at `legibleStartWidth` so firmware text stays readable. A suspended machine keeps the
    /// size it was suspended with, because saved state only restores into an identical configuration.
    static func displaySize(for config: VMConfig, windowSize: CGSize?, restoring: Bool) -> (width: Int, height: Int) {
        if restoring, let width = config.lastDisplayWidth, let height = config.lastDisplayHeight { return (width, height) }
        guard config.fitsWindowAtStart, let windowSize, windowSize.width >= 320, windowSize.height >= 200 else {
            return (config.displayWidth, config.displayHeight)
        }
        var width = windowSize.width * config.displayScale
        var height = windowSize.height * config.displayScale
        if config.guest == .linux, width > Double(legibleStartWidth) {
            height *= Double(legibleStartWidth) / width
            width = Double(legibleStartWidth)
        }
        // Clamp as a Double first: Int(value) traps for a value that is NaN or past Int.max.
        func even(_ value: Double, _ range: ClosedRange<Int>) -> Int {
            let bounded = min(max(value.isNaN ? 0 : value, Double(range.lowerBound)), Double(range.upperBound))
            return min(max(Int(bounded) & ~1, range.lowerBound), range.upperBound)
        }
        return (even(width, 640...7680), even(height, 480...4320))
    }

    /// A validated configuration, and the user-mode network stack its NIC talks to when the machine is `.filtered`.
    ///
    /// The stack is created but **not started**: the caller starts it before the machine and must stop it on every path
    /// that ends the machine, and must not reuse it for a second configuration (a stack serves one NIC for one run).
    struct Built {
        let configuration: VZVirtualMachineConfiguration
        let networkStack: UserNetStack?
    }

    static func build(_ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int)? = nil) throws -> Built {
        let display = display ?? (config.displayWidth, config.displayHeight)
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = min(max(config.cpuCount, cpuRange.lowerBound), cpuRange.upperBound)
        vz.memorySize = UInt64(min(max(config.memoryMiB, memoryRangeMiB.lowerBound), memoryRangeMiB.upperBound)) << 20

        switch config.guest {
        case .macOS: try configureMac(vz, config, bundle, display)
        case .linux: try configureLinux(vz, config, bundle, display)
        }

        vz.storageDevices += try storage(for: config, bundle: bundle)
        let network = try network(for: config)
        vz.networkDevices = network.devices
        if let sound = sound(for: config) { vz.audioDevices = [sound] }
        if config.entropyDevice { vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()] }
        if config.memoryBalloon { vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()] }
        if config.socketDevice { vz.socketDevices = [VZVirtioSocketDeviceConfiguration()] }
        vz.directorySharingDevices += try directoryShares(for: config)

        try vz.validate()
        return Built(configuration: vz, networkStack: network.stack)
    }

    // MARK: macOS

    private static func configureMac(
        _ vz: VZVirtualMachineConfiguration, _ config: VMConfig, _ bundle: VMBundle, _ display: (width: Int, height: Int)
    ) throws {
        let platform = VZMacPlatformConfiguration()
        guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: bundle.hardwareModel)),
            let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdentifier))
        else { throw SetupError.missingFile(bundle.hardwareModel.path) }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.activeAuxiliaryStorage(ephemeral: config.ephemeral))
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        // The framework supports exactly one display per graphics device.
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: display.width, heightInPixels: display.height,
                pixelsPerInch: min(max(config.pixelsPerInch, EditorLimits.pixelsPerInch.lowerBound), EditorLimits.pixelsPerInch.upperBound)
            )
        ]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZMacKeyboardConfiguration()]
        vz.pointingDevices = [
            config.pointingDevice == .trackpad
                ? VZMacTrackpadConfiguration()
                : VZUSBScreenCoordinatePointingDeviceConfiguration()
        ]
    }

    // MARK: Linux

    private static func configureLinux(
        _ vz: VZVirtualMachineConfiguration, _ config: VMConfig, _ bundle: VMBundle, _ display: (width: Int, height: Int)
    ) throws {
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: bundle.machineIdentifier),
            let identifier = VZGenericMachineIdentifier(dataRepresentation: data)
        {
            platform.machineIdentifier = identifier
        }
        if config.nestedVirtualization {
            guard VZGenericPlatformConfiguration.isNestedVirtualizationSupported else {
                throw SetupError.unsupportedHost("Nested virtualization needs an M3 or newer chip.")
            }
            platform.isNestedVirtualizationEnabled = true
        }
        vz.platform = platform

        let variableStore = VZEFIVariableStore(url: bundle.activeEFIVariables(ephemeral: config.ephemeral))
        try applySecureBoot(config.secureBoot, to: variableStore)
        let boot = VZEFIBootLoader()
        boot.variableStore = variableStore
        vz.bootLoader = boot

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        // The framework supports exactly one scanout per graphics device.
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: display.width, heightInPixels: display.height)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        if config.sharesClipboard {
            let attachment = VZSpiceAgentPortAttachment()
            attachment.sharesClipboard = true
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            port.attachment = attachment
            let console = VZVirtioConsoleDeviceConfiguration()
            console.ports[0] = port
            vz.consoleDevices = [console]
        }
    }

    /// Enrolls the Apple platform key and Microsoft's UEFI keys (so Microsoft-signed distro shims, like
    /// CentOS's, still boot) and turns enforcement on or off to match the setting.
    private static func applySecureBoot(_ wanted: Bool, to store: VZEFIVariableStore) throws {
        guard #available(macOS 27.0, *) else {
            if wanted { throw SetupError.unsupportedHost("Secure Boot needs macOS 27 or later on the host.") }
            return
        }
        let enabled = (try? store.isSecureBootEnabled) ?? false
        if wanted, !enabled {
            try store.enrollDefaultSecureBootSignatures()
            try store.enableSecureBootUsingDefaultPlatformKey()
        } else if !wanted, enabled {
            try store.disableSecureBoot()
        }
    }

    // MARK: Shared devices

    static func storage(for config: VMConfig, bundle: VMBundle) throws -> [VZStorageDeviceConfiguration] {
        func attachment(_ url: URL, readOnly: Bool) throws -> VZDiskImageStorageDeviceAttachment {
            try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: readOnly,
                cachingMode: config.diskCaching.vz, synchronizationMode: config.diskSync.vz
            )
        }

        var devices: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: try attachment(bundle.activeDisk(ephemeral: config.ephemeral), readOnly: false))
        ]
        for disk in config.extraDisks {
            guard FileManager.default.fileExists(atPath: disk.path) else { throw SetupError.missingFile(disk.path) }
            devices.append(
                VZVirtioBlockDeviceConfiguration(
                    attachment: try attachment(URL(filePath: disk.path), readOnly: disk.readOnly)))
        }
        if let iso = config.attachedInstallerPath {
            guard FileManager.default.fileExists(atPath: iso) else { throw SetupError.missingFile(iso) }
            let readOnly = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: iso), readOnly: true)
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: readOnly))
        }
        return devices
    }

    private static func network(for config: VMConfig) throws -> (devices: [VZNetworkDeviceConfiguration], stack: UserNetStack?) {
        guard config.networkMode.hasNetworkDevice else { return ([], nil) }
        let device = VZVirtioNetworkDeviceConfiguration()
        var stack: UserNetStack?
        if config.networkMode == .filtered {
            let user = try UserNetStack.attachment(
                config: config.userNetConfig, policy: config.networkPolicy, pathChangeAction: config.hostPathChangeAction)
            device.attachment = user.attachment
            stack = user.stack
        } else {
            device.attachment = VZNATNetworkDeviceAttachment()
        }
        if let mac = config.macAddress.flatMap({ VZMACAddress(string: $0) }) { device.macAddress = mac }
        return ([device], stack)
    }

    private static func sound(for config: VMConfig) -> VZVirtioSoundDeviceConfiguration? {
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
        if config.audioOutput {
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            streams.append(output)
        }
        if config.audioInput {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        guard !streams.isEmpty else { return nil }
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = streams
        return sound
    }

    private static func directoryShares(for config: VMConfig) throws -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []

        if !config.sharedFolders.isEmpty {
            var directories: [String: VZSharedDirectory] = [:]
            for folder in config.sharedFolders {
                guard FileManager.default.fileExists(atPath: folder.path) else { throw SetupError.missingFile(folder.path) }
                var name = folder.name
                var suffix = 2
                while directories[name] != nil {
                    name = "\(folder.name)-\(suffix)"
                    suffix += 1
                }
                directories[name] = VZSharedDirectory(url: URL(filePath: folder.path), readOnly: folder.readOnly)
            }
            let tag = config.guest == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : linuxShareTag
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            device.share = VZMultipleDirectoryShare(directories: directories)
            devices.append(device)
        }

        if config.guest == .linux, config.rosetta {
            guard VZLinuxRosettaDirectoryShare.availability == .installed else { throw SetupError.rosettaUnavailable }
            let device = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
            device.share = try VZLinuxRosettaDirectoryShare()
            devices.append(device)
        }
        return devices
    }
}

extension DiskCaching {
    var vz: VZDiskImageCachingMode {
        switch self {
        case .automatic: .automatic
        case .cached: .cached
        case .uncached: .uncached
        }
    }
}

extension DiskSync {
    var vz: VZDiskImageSynchronizationMode {
        switch self {
        case .full: .full
        case .fsync: .fsync
        case .none: .none
        }
    }
}

extension VMConfig {
    /// Guest pixels per window point: macOS follows its configured density, Linux follows `pixelsPerPoint`.
    var displayScale: Double {
        guest == .macOS ? Double(pixelsPerInch) / 72 : Double(max(1, pixelsPerPoint))
    }
}

/// Why a user-mode stack could not be created, in words for the error alert.
extension UserNetError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let problem): "The filtered network can't be set up: \(problem)."
        case .systemCall(let code): "The filtered network can't be set up (system error \(code))."
        }
    }
}
