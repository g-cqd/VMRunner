import Foundation
import VirtioGPU
import VirtioGPURunnerCore
import Virtualization

/// Why the configuration could not be built.
struct RunnerFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// A headless Linux machine whose only display is the host-implemented GPU device: EFI boot from a raw disk, an optional
/// read-only seed disk, entropy, a serial console written to a file, no network, no keyboard, no pointer and none of the
/// framework's own graphics devices.
@available(macOS 27.0, *)
@MainActor
enum MachineBuilder {
    /// With `creatingFiles` the EFI variable store and the console log are created in the scratch directory (a real start);
    /// without it nothing is written (a dry run) and the console goes nowhere.
    static func build(_ options: RunnerOptions, device: GPUDevice, creatingFiles: Bool) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = options.cpuCount
        configuration.memorySize = UInt64(options.memoryMiB) << 20
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.bootLoader = try bootLoader(options, creatingFiles: creatingFiles)
        configuration.storageDevices = try storage(options)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.serialPorts = [try console(options, creatingFiles: creatingFiles)]
        configuration.customVirtioDevices = [gpu(device)]
        return configuration
    }

    /// The virtio GPU: device 16 on a display class, a control and a cursor queue, version 1 and no optional feature
    /// (two-dimensional only), one scanout and no capability set.
    static func gpu(_ device: GPUDevice) -> VZCustomVirtioDeviceConfiguration {
        let gpu = VZCustomVirtioDeviceConfiguration()
        gpu.deviceID = GPUWire.deviceID
        gpu.pciClassID = GPUWire.pciClassID
        gpu.pciSubclassID = GPUWire.pciSubclassID
        gpu.virtioQueueCount = GPUWire.queueCount
        gpu.mandatoryFeatures.subset1 = GPUWire.versionOneFeatureSubset1
        let space = GPUConfigSpace(eventsRead: 0, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
        gpu.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: Data(space.bytes))
        gpu.supportsSaveRestore = false
        // The provider keeps its delegate weakly: the runner holds `device` for as long as the machine lives.
        gpu.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: .main, delegate: device)
        return gpu
    }

    private static func requireFile(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw RunnerFailure("\(path) does not exist") }
    }

    private static func bootLoader(_ options: RunnerOptions, creatingFiles: Bool) throws -> VZBootLoader {
        let loader = VZEFIBootLoader()
        let url = URL(filePath: options.variableStorePath)
        if FileManager.default.fileExists(atPath: url.path) || !creatingFiles {
            loader.variableStore = VZEFIVariableStore(url: url)
        } else {
            do {
                loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: url)
            } catch {
                throw RunnerFailure("cannot create the EFI variable store \(url.path): \(error.localizedDescription)")
            }
        }
        return loader
    }

    private static func storage(_ options: RunnerOptions) throws -> [VZStorageDeviceConfiguration] {
        var devices: [VZStorageDeviceConfiguration] = []
        for (path, readOnly) in [(options.disk, false)] + (options.seed.map { [($0, true)] } ?? []) {
            try requireFile(path)
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: path), readOnly: readOnly)
                devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            } catch {
                throw RunnerFailure("cannot attach \(path): \(error.localizedDescription)")
            }
        }
        return devices
    }

    /// The guest's serial console, output only, to `console.log` (created private) or, in a dry run, to nothing.
    private static func console(_ options: RunnerOptions, creatingFiles: Bool) throws -> VZSerialPortConfiguration {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        let output: FileHandle
        if creatingFiles {
            guard FileManager.default.createFile(atPath: options.consoleLogPath, contents: nil, attributes: [.posixPermissions: 0o600]),
                let handle = FileHandle(forWritingAtPath: options.consoleLogPath)
            else { throw RunnerFailure("cannot create \(options.consoleLogPath)") }
            output = handle
        } else {
            // The framework refuses `FileHandle.nullDevice` (an exception, not an error); an opened /dev/null is accepted.
            guard let handle = FileHandle(forWritingAtPath: "/dev/null") else { throw RunnerFailure("cannot open /dev/null") }
            output = handle
        }
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: output)
        return port
    }
}
