import Virtualization

extension ConfigurationBuilder {
    /// The generic platform of a Linux or Windows guest: the machine's identifier, when its bundle has one, and nested
    /// virtualization when the machine asks for it and the host can do it.
    static func genericPlatform(for config: VMConfig, bundle: VMBundle) throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: bundle.activeMachineIdentifier(ephemeral: config.ephemeral)),
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
        return platform
    }

    /// The EFI boot loader of a Linux or Windows guest, with the machine's variable store set to `secureBoot`.
    static func efiBootLoader(for config: VMConfig, bundle: VMBundle, secureBoot: Bool) throws -> VZEFIBootLoader {
        let variableStore = VZEFIVariableStore(url: bundle.activeEFIVariables(ephemeral: config.ephemeral))
        try applySecureBoot(secureBoot, to: variableStore)
        let boot = VZEFIBootLoader()
        boot.variableStore = variableStore
        return boot
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
}
