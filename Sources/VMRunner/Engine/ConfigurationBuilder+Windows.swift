import Foundation
import PrivateInterfaces
import Virtualization
import os

extension ConfigurationBuilder {
    /// A Windows guest: the generic platform with the EFI boot loader (Secure Boot off), the framework's graphics device and
    /// its USB keyboard and pointer. The NVMe main disk, the installer and the driver disc, the network and the sound come from
    /// the devices every guest shares. It has no serial console, no cloud-init seed and no Rosetta, and no guest agent: the
    /// clipboard setting is inert for it. Shared folders are not special-cased: they use the shared device and tag, which
    /// a Windows guest sees only with a virtio file system driver of its own.
    ///
    /// The machine needs the performance-monitoring emulation to boot Windows. It is turned on through the capability module
    /// when the policy allows it; when the policy denies it or the capability is unavailable, the start fails with a message
    /// that names the capability and why, unless the developer default lets the machine start without it.
    static func configureWindows(
        _ vz: VZVirtualMachineConfiguration, _ config: VMConfig, _ bundle: VMBundle, _ display: (width: Int, height: Int),
        settings: WindowsStartSettings
    ) throws {
        let platform = try genericPlatform(for: config, bundle: bundle)
        try requirePerformanceMonitoring(on: platform, settings: settings)
        vz.platform = platform
        vz.bootLoader = try efiBootLoader(for: config, bundle: bundle, secureBoot: false)
        try configureLinuxScreen(vz, config, display, customGPU: nil)
    }

    /// Turns the emulation on for `platform`. A reason it is off ends the start, or is logged once when the developer default
    /// asks to start anyway.
    private static func requirePerformanceMonitoring(
        on platform: VZGenericPlatformConfiguration, settings: WindowsStartSettings
    ) throws {
        let capability = PrivateCapabilityID.performanceMonitoringEmulation
        let reason: String
        switch settings.decision {
        case .denied(let denial):
            reason = denial.description
        case .allowed:
            guard case .unavailable(let unavailable) = settings.applyPerformanceMonitoring(platform) else { return }
            reason = unavailable.description
        }
        guard settings.startsWithoutPerformanceMonitoring else {
            throw SetupError.requiredCapabilityUnavailable(guest: .windows, capability: capability.title, reason: reason)
        }
        let (name, key) = (capability.title, WindowsStartsWithoutPMU.defaultsKey)
        Log.machine.notice(
            "Windows starts without the \(name, privacy: .public) (\(reason, privacy: .public)): \(key, privacy: .public) is on")
    }

    /// The driver disc of a Windows machine as a read-only USB drive, or nil when it has none. A file the guest reads whole is
    /// a host channel like an extra disk: it must exist and must not be a file inside the Machines folder.
    static func driverDisc(for config: VMConfig) throws -> VZUSBMassStorageDeviceConfiguration? {
        guard let path = config.attachedDriverDiscPath else { return nil }
        guard !AppPaths.isInside(URL(filePath: path), AppPaths.machines) else { throw HostPathError.insideMachinesFolder(path) }
        guard FileManager.default.fileExists(atPath: path) else { throw SetupError.missingFile(path) }
        let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: path), readOnly: true)
        return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
    }
}
