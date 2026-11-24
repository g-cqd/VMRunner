import Virtualization

/// A machine's custom GPU as the rest of the app sees it: the screen its window draws, and the device the engine puts in the
/// machine's configuration. Nothing of the device's code is visible through it, and it needs no macOS 27 type to be named, so
/// the controller, the machine's model and the window hold it on every host. Whoever builds the machine holds the source for
/// as long as the machine lives, because the framework holds the device it makes weakly.
@MainActor
protocol CustomDisplaySource: AnyObject, Sendable {
    /// The picture and the cursor the guest draws.
    var screen: CustomScreen { get }

    /// A framebuffer overlay leaves Apple's firmware view/input visible until the guest draws.
    nonisolated var prefersFrameworkOverlay: Bool { get }
    func beginDisplay(for machine: VZVirtualMachine, failure: @escaping @MainActor (String) -> Void)
    func endDisplay()

    /// What carries the machine's keyboard and pointer from the window to the guest.
    var input: any GuestInputSurface { get }

    /// Asks the guest to resize its display to `width` × `height` pixels. `false` means the device refuses that size and changed
    /// nothing; `true` means the guest is being told, not that it has drawn at the new size (the screen shows that when frames
    /// of the new size arrive).
    func requestDisplaySize(width: UInt32, height: UInt32) -> Bool

    /// The device for `VZVirtualMachineConfiguration.customVirtioDevices`. It is made off the main actor, with the rest of the
    /// configuration; the framework calls the device back on the main queue.
    @available(macOS 27.0, *)
    nonisolated func makeConfiguration() -> VZCustomVirtioDeviceConfiguration

    /// The devices of the input path, which follow the GPU in the machine's `customVirtioDevices`. Empty when the framework's
    /// USB keyboard and pointer carry the input.
    @available(macOS 27.0, *)
    nonisolated func makeInputConfigurations() -> [VZCustomVirtioDeviceConfiguration]
}

extension CustomDisplaySource {
    nonisolated var prefersFrameworkOverlay: Bool { false }
    func beginDisplay(for machine: VZVirtualMachine, failure: @escaping @MainActor (String) -> Void) {}
    func endDisplay() {}
}
