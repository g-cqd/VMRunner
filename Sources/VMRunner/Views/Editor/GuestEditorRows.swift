/// Which guest-specific rows of the machine editor a guest gets. The sections ask here instead of comparing the guest, so what
/// a Windows machine is shown (and not shown) is stated in one place and a test can read it.
///
/// A Windows machine shows the hardware it has: processors, memory, a disk that can grow, the installer and a driver disc,
/// network, display size, sound, input, shared folders and host information (with a note that the guest needs a driver of its
/// own for them), nested virtualization where the host can do it, and snapshots of its disk. It does not show what only a Linux
/// or macOS machine has: a serial console, Rosetta, the clipboard agent, provisioning, a graphics device choice, a disk
/// interface choice, Secure Boot, or the switch that allows suspend.
struct GuestEditorRows: Equatable {
    let guest: GuestOS

    init(_ guest: GuestOS) { self.guest = guest }

    // Sections
    var installer: Bool { guest.usesGenericPlatform }
    var provisioning: Bool { guest == .linux }
    var firstBoot: Bool { guest == .macOS }

    // Rows
    var driverDisc: Bool { guest == .windows }
    var graphicsDevice: Bool { guest == .linux }
    var pixelDensity: Bool { guest == .macOS }
    var linuxDisplayNote: Bool { guest == .linux }
    var pixelsPerPoint: Bool { guest == .linux }
    var pointingDevice: Bool { guest == .macOS }
    var nestedVirtualization: Bool { guest.usesGenericPlatform }
    var serialConsole: Bool { guest != .windows }
    var clipboardAndRosetta: Bool { guest == .linux }
    var diskInterface: Bool { guest == .linux }
    var secureBoot: Bool { guest == .linux }
    var allowSuspend: Bool { guest != .windows }
    var windowsNotes: Bool { guest == .windows }
}
