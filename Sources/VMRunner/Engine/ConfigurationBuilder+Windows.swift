import Foundation
import PrivateInterfaces
import Virtualization
import os

extension ConfigurationBuilder {
    /// ADR-0060: the app uses the owned EFI framebuffer boot medium, both checked switches and the host RAM display.
    /// The normal graphics device and USB input remain for firmware and owner input. Common storage adds the Virtio target,
    /// read-only installer/driver media and network. No console, provisioning seed, Rosetta or guest-agent promise is added.
    /// Only legacy diagnostics without a prepared medium use the independent PMU path and its original unsafe-build guard.
    static func configureWindows(
        _ vz: VZVirtualMachineConfiguration, _ config: VMConfig, _ bundle: VMBundle, _ display: (width: Int, height: Int),
        settings: WindowsStartSettings, source: (any CustomDisplaySource)? = nil, boot: WindowsBootMedia? = nil
    ) throws {
        let platform = try genericPlatform(for: config, bundle: bundle)
        if let boot {
            guard #available(macOS 27.0, *), let source, source.prefersFrameworkOverlay,
                config.diskInterface == .virtio, !config.nestedVirtualization
            else {
                throw SetupError.requiredCapabilityUnavailable(
                    guest: .windows, capability: "framebuffer-assisted boot",
                    reason: "it needs macOS 27, its RAM display, Virtio storage and nested virtualization off")
            }
            let reason: String?
            switch settings.decision {
            case .denied(let denied): reason = denied.description
            case .allowed:
                if case .unavailable(let unavailable) = settings.applyFramebufferBoot(platform) {
                    reason = unavailable.description
                } else {
                    reason = nil
                }
            }
            // The old diagnostic bypass NEVER relaxes prerequisites of the framebuffer boot path.
            if let reason {
                throw SetupError.requiredCapabilityUnavailable(guest: .windows, capability: "framebuffer-assisted boot", reason: reason)
            }
            vz.customVirtioDevices = [source.makeConfiguration()]
            let attachment = try VZDiskImageStorageDeviceAttachment(url: boot.url, readOnly: true)
            vz.storageDevices = [VZUSBMassStorageDeviceConfiguration(attachment: attachment)]
            try configureLinuxScreen(vz, config, (1920, 1200), customGPU: nil)
        } else {
            // Legacy diagnostic callers retain the independent, fail-closed PMU guard. The app factory always supplies boot.
            try requirePerformanceMonitoring(on: platform, settings: settings)
            try configureLinuxScreen(vz, config, display, customGPU: nil)
        }
        vz.platform = platform
        if let boot {
            let loader = VZEFIBootLoader()
            loader.variableStore = VZEFIVariableStore(url: boot.variables)
            vz.bootLoader = loader
        } else {
            vz.bootLoader = try efiBootLoader(for: config, bundle: bundle, secureBoot: false)
        }
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
