import Foundation
import GuestConsole
import NetStack
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

    /// `build` away from the caller's actor. It reads the auxiliary storage and validates the configuration, which held the
    /// main thread for 150 to 300 ms at a machine's start (roadmap 0037). What it builds is new and shared with nobody, so it
    /// is sent back to the caller.
    @concurrent
    static func buildInBackground(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int)? = nil
    ) async throws -> sending Built {
        try build(config, bundle: bundle, display: display)
    }

    /// A validated configuration, and the user-mode network stack its NIC talks to when the machine is `.filtered`.
    ///
    /// The stack is created but **not started**: the caller starts it before the machine and must stop it on every path
    /// that ends the machine, and must not reuse it for a second configuration (a stack serves one NIC for one run).
    struct Built {
        let configuration: VZVirtualMachineConfiguration
        let networkStack: UserNetStack?
        /// The bridge that serves the guest's serial console on a local socket, when the machine has one. It is bound but not
        /// running: the caller starts it with the machine and keeps it for as long as the machine lives, and it ends by itself
        /// when the guest side of the port closes. A bridge that is released without having started removes its socket.
        let consoleBridge: ConsoleBridge?
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
        let console = try serialConsole(for: config, bundle: bundle)
        if let console { vz.serialPorts = [console.port] }

        try vz.validate()
        return Built(configuration: vz, networkStack: network.stack, consoleBridge: console?.bridge)
    }

    // MARK: Serial console

    /// The guest's first serial port (`hvc0`) joined to a bridge that serves it on a local socket, for a Linux guest whose
    /// console switch is on. macOS guests have no such port here.
    private static func serialConsole(
        for config: VMConfig, bundle: VMBundle
    ) throws -> (port: VZSerialPortConfiguration, bridge: ConsoleBridge)? {
        guard config.guest == .linux, config.serialConsole else { return nil }
        let placement = bundle.consoleSocket()
        do {
            try ConsoleBridge.makePrivateDirectory(at: placement.directory)
            let pair = try ConsoleBridge.makeGuestPair()
            let bridge: ConsoleBridge
            let handles: (reading: FileHandle, writing: FileHandle)
            do {
                handles = try pair.guestHandles()
                bridge = try ConsoleBridge(guestDescriptor: pair.host, socketPath: placement.path)
            } catch {
                close(pair.host)
                throw error
            }
            let port = VZVirtioConsoleDeviceSerialPortConfiguration()
            port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: handles.reading, fileHandleForWriting: handles.writing)
            return (port, bridge)
        } catch {
            throw SetupError.consoleUnavailable(reason: "\(error)")
        }
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
            guard !AppPaths.isInside(URL(filePath: disk.path), AppPaths.machines) else {
                throw HostPathError.insideMachinesFolder(disk.path)
            }
            guard FileManager.default.fileExists(atPath: disk.path) else { throw SetupError.missingFile(disk.path) }
            devices.append(
                VZVirtioBlockDeviceConfiguration(
                    attachment: try attachment(URL(filePath: disk.path), readOnly: disk.readOnly)))
        }
        if let path = config.attachedInstallerPath {
            let iso = bundle.installerFile(for: path)
            guard FileManager.default.fileExists(atPath: iso.path) else { throw SetupError.missingFile(iso.path) }
            let readOnly = try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
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
                config: config.userNetConfig, policy: config.networkPolicy, pathChangeAction: config.hostPathChangeAction,
                logger: AppUserNetLogger())
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
