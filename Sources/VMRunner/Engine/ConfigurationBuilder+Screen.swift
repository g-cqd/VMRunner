import Virtualization

extension ConfigurationBuilder {
    /// A Linux guest's screen and the keyboard and pointer that go with it. The framework's graphics device is the default; a
    /// machine set to the custom GPU gets that device instead, as a custom virtio device, and no framework graphics device at
    /// all. The USB keyboard and pointer stay, except on the custom GPU's virtio input path, whose two input devices follow the
    /// GPU in the custom devices and replace them (the guest then sees only virtio input). A host older than macOS 27 cannot
    /// build the custom device, and then `customGPU` is `nil` (`VZMachineFactory.prepare` makes it only where it can).
    static func configureLinuxScreen(
        _ vz: VZVirtualMachineConfiguration, _ config: VMConfig, _ display: (width: Int, height: Int),
        customGPU: (any CustomDisplaySource)?
    ) throws {
        var usesUSBInput = true
        if config.usesCustomGPU {
            guard #available(macOS 27.0, *), let customGPU else {
                throw SetupError.unsupportedHost("The custom GPU needs macOS 27 or later on the host.")
            }
            let input = customGPU.makeInputConfigurations()
            vz.customVirtioDevices = [customGPU.makeConfiguration()] + input
            usesUSBInput = input.isEmpty
        } else {
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            // The framework supports exactly one scanout per graphics device.
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: display.width, heightInPixels: display.height)]
            vz.graphicsDevices = [graphics]
        }
        if usesUSBInput {
            vz.keyboards = [VZUSBKeyboardConfiguration()]
            vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
    }
}
