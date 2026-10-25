extension HelpCatalog {
    static let windows: [HelpTopic: HelpEntry] = [
        .windowsMachines: HelpEntry(
            area: .start,
            title: "Windows guests (experimental)",
            summary: "Windows 11 on ARM is an experimental guest, from your installer and licence. It has not been verified to boot.",
            paragraphs: [
                "You can try Windows 11 on ARM as an experimental guest. You bring the installer: "
                    + "VMRunner never downloads Windows. Pick **Windows** in the New Machine sheet and choose an ARM64 installer ISO "
                    + "from your Mac.",
                "• **Installer**: a local ISO. If you type its SHA-256 in *Expected SHA-256*, VMRunner reads the file before it "
                    + "makes the machine and stops if the digest differs or is not 64 hexadecimal digits. Leave it empty to skip "
                    + "the check. The SHA-256, when you type one, is checked once, at creation.",
                "• **Driver disc** (optional): another ISO, attached as a second read-only USB drive. You can add, change or "
                    + "remove it later in the machine's settings.",
                "• **Defaults**: 4 processors and 8 GiB of memory (less on a small Mac), a 64 GiB sparse NVMe disk, NAT "
                    + "networking and a 1920 × 1200 display. Sound is off because Windows has no built-in driver for it; turn it "
                    + "on in the settings if you add one.",
                "Before you start:",
            ] + WindowsRequirements.lines.map { "• " + $0 } + [
                "The settings show only what a Windows machine has. Shared folders and host information reach the guest only if "
                    + "you install a virtio file-system driver in it. Snapshots of the disk work while the machine is stopped."
            ],
            advanced: [
                "The machine is built from the framework's generic platform with an EFI boot loader (Secure Boot off), an NVMe "
                    + "disk, a USB keyboard and pointer, and virtio graphics and network devices. The installer and the driver disc "
                    + "are USB mass-storage drives, attached read-only.",
                "Performance-monitoring emulation is a private interface. If it is unavailable or turned off, the machine does "
                    + "not start and the message names the reason: the profile, the managed setting, the developer default or the "
                    + "macOS build. See Private interfaces.",
            ],
            related: [.privateInterfaces, .installerISO, .securityProfiles, .guestSystems, .limits]
        )
    ]
}
