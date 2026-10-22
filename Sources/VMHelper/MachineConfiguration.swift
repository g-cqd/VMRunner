import Foundation
import GuestConsole
import NetPolicy
import NetStack
import VMHelperCore
import Virtualization

/// Translates a descriptor into a validated `VZVirtualMachineConfiguration`.
///
/// This is a copy of the minimum of the app's `ConfigurationBuilder` (Linux, EFI or kernel boot, disks, an ISO, entropy,
/// NAT, a serial console) so the helper does not depend on the app target. Extracting one shared builder is a follow-up: the app's builder
/// reads `VMConfig` and `VMBundle`, which pull in most of the model layer.
enum MachineConfiguration {
    /// A validated configuration plus what must outlive it: the host end of the socket pair of a `fileHandle` network, the
    /// bridge's end of the console's socket pair, and the user-mode stack of a `filtered` network (created, not started).
    struct Built {
        let configuration: VZVirtualMachineConfiguration
        let hostDescriptor: Int32?
        let consoleDescriptor: Int32?
        let networkStack: UserNetStack?

        /// Closes what a configuration that is not going to run holds.
        func release() {
            if let hostDescriptor { close(hostDescriptor) }
            if let consoleDescriptor { close(consoleDescriptor) }
        }
    }

    /// Builds and validates the configuration. With `creatingVariableStore` a missing EFI variable store is created (a real
    /// start); without it the store is only named (a dry run, which must not write anything).
    static func build(_ descriptor: HelperDescriptor, creatingVariableStore: Bool) throws -> Built {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = min(
            max(descriptor.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = UInt64(max(descriptor.memoryMiB, 1)) << 20
        configuration.memorySize = min(
            max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.bootLoader = try bootLoader(descriptor, creatingVariableStore: creatingVariableStore)
        configuration.storageDevices = try storage(descriptor)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        let console = try console(descriptor)
        configuration.serialPorts = [console.port]
        let network: Network
        do {
            network = try self.network(descriptor)
        } catch {
            if let host = console.hostDescriptor { close(host) }
            throw error
        }
        configuration.networkDevices = network.devices

        let built = Built(
            configuration: configuration, hostDescriptor: network.hostDescriptor, consoleDescriptor: console.hostDescriptor,
            networkStack: network.stack)
        do {
            try configuration.validate()
        } catch {
            built.release()
            throw HelperFailure.configurationRejected("the framework rejected the configuration: \(error.localizedDescription)")
        }
        return built
    }

    private static func requireFile(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw HelperFailure.missingFile("\(path) does not exist, or the sandbox hides it")
        }
    }

    private static func bootLoader(_ descriptor: HelperDescriptor, creatingVariableStore: Bool) throws -> VZBootLoader {
        switch descriptor.boot.kind {
        case .efi:
            guard let path = descriptor.boot.variableStore else {
                throw HelperFailure.invalidDescriptor("an efi boot needs a variableStore")
            }
            let loader = VZEFIBootLoader()
            let url = URL(filePath: path)
            if FileManager.default.fileExists(atPath: path) || !creatingVariableStore {
                loader.variableStore = VZEFIVariableStore(url: url)
            } else {
                do {
                    loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: url)
                } catch {
                    throw HelperFailure.virtualMachine("cannot create the EFI variable store \(path): \(error.localizedDescription)")
                }
            }
            return loader
        case .kernel:
            guard let kernel = descriptor.boot.kernel else { throw HelperFailure.invalidDescriptor("a kernel boot needs a kernel") }
            try requireFile(kernel)
            let loader = VZLinuxBootLoader(kernelURL: URL(filePath: kernel))
            if let initrd = descriptor.boot.initrd {
                try requireFile(initrd)
                loader.initialRamdiskURL = URL(filePath: initrd)
            }
            loader.commandLine = descriptor.boot.commandLine ?? "console=hvc0"
            return loader
        }
    }

    private static func storage(_ descriptor: HelperDescriptor) throws -> [VZStorageDeviceConfiguration] {
        var devices: [VZStorageDeviceConfiguration] = []
        for disk in descriptor.disks {
            try requireFile(disk.path)
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: disk.path), readOnly: disk.readOnly)
                devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            } catch {
                throw HelperFailure.configurationRejected("cannot attach \(disk.path): \(error.localizedDescription)")
            }
        }
        if let iso = descriptor.installerISO {
            try requireFile(iso)
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: iso), readOnly: true)
                devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            } catch {
                throw HelperFailure.configurationRejected("cannot attach \(iso): \(error.localizedDescription)")
            }
        }
        return devices
    }

    /// The guest's first serial port. With a console in the descriptor it is one end of a socket pair whose other end the bridge
    /// serves; without one the guest's output goes to the helper's standard error, which carries no events.
    private static func console(_ descriptor: HelperDescriptor) throws -> (port: VZSerialPortConfiguration, hostDescriptor: Int32?) {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        guard descriptor.console != nil else {
            port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: .standardError)
            return (port, nil)
        }
        let pair: ConsoleBridge.GuestPair
        do {
            pair = try ConsoleBridge.makeGuestPair()
        } catch {
            throw HelperFailure.virtualMachine("cannot create the console's socket pair: \(error)")
        }
        do {
            let handles = try pair.guestHandles()
            port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: handles.reading, fileHandleForWriting: handles.writing)
        } catch {
            close(pair.host)
            throw HelperFailure.virtualMachine("cannot hand the console's socket to the serial port: \(error)")
        }
        return (port, pair.host)
    }

    /// The network card, if any, and what keeps it alive.
    private struct Network {
        var devices: [VZNetworkDeviceConfiguration] = []
        /// The host end of a `fileHandle` network's socket pair.
        var hostDescriptor: Int32?
        /// The user-mode stack of a `filtered` network.
        var stack: UserNetStack?
    }

    private static func network(_ descriptor: HelperDescriptor) throws -> Network {
        switch descriptor.network {
        case .none:
            return Network()
        case .nat:
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            return Network(devices: [device])
        case .fileHandle:
            guard let pair = DatagramPair.make() else {
                throw HelperFailure.virtualMachine("cannot create the datagram socket pair for the network (errno \(errno))")
            }
            let device = VZVirtioNetworkDeviceConfiguration()
            // The attachment owns the guest end; the helper keeps the host end open for as long as the machine runs.
            device.attachment = VZFileHandleNetworkDeviceAttachment(
                fileHandle: FileHandle(fileDescriptor: pair.guest, closeOnDealloc: true))
            return Network(devices: [device], hostDescriptor: pair.host)
        case .filtered:
            return try filteredNetwork(descriptor)
        }
    }

    /// A virtio card on one end of the stack's socket pair, as the app's `UserNetStack.attachment` makes it. That glue needs
    /// Virtualization.framework, which the stack's library does not link, so the helper has its own copy of the few lines.
    private static func filteredNetwork(_ descriptor: HelperDescriptor) throws -> Network {
        var config = UserNetConfig()
        config.denyAction = descriptor.denyAction == .drop ? .drop : .reset
        let policy = try PolicyFile.load(descriptor.networkPolicy)
        let made: (guestDescriptor: Int32, stack: UserNetStack)
        do {
            made = try UserNetStack.make(config: config, policy: policy)
        } catch {
            throw HelperFailure.virtualMachine("cannot create the user-mode network: \(error)")
        }
        let handle = FileHandle(fileDescriptor: made.guestDescriptor, closeOnDealloc: true)
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        attachment.maximumTransmissionUnit = config.mtu
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = attachment
        return Network(devices: [device], stack: made.stack)
    }
}

/// A connected pair of `AF_UNIX` datagram sockets, the shape a file-handle network attachment needs.
enum DatagramPair {
    /// Send buffer size; the receive buffer is four times that (the framework asks for at least double).
    static let bufferSize = 128 << 10

    static func make() -> (guest: Int32, host: Int32)? {
        var descriptors: [Int32] = [-1, -1]
        // `socketpair` fills exactly two descriptors.
        guard unsafe socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else { return nil }
        var send = Int32(bufferSize)
        var receive = Int32(bufferSize * 4)
        let size = socklen_t(MemoryLayout<Int32>.size)
        for descriptor in descriptors {
            // Each call reads one Int32 from the stack.
            _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &send, size)
            _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receive, size)
        }
        return (descriptors[0], descriptors[1])
    }
}
