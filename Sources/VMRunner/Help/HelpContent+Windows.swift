extension HelpCatalog {
    static let windows: [HelpTopic: HelpEntry] = [
        .windowsMachines: HelpEntry(
            area: .start,
            title: "Windows guests (experimental)",
            summary: "Windows ARM with a framebuffer bootstrap, ARM64 storage drivers and explicit hardware limits.",
            paragraphs: [
                "Choose **Windows** in New Machine for an experimental guest; supply a Windows 11 ARM64 installer and your licence. "
                    + "VMRunner never downloads Windows.",
                "• **Installer**: a local ISO, attached read-only. An optional **Expected SHA-256** is checked before creation; "
                    + "a mismatch stops creation.",
                "• **Driver disc**: supply a virtio-win ARM64 disc for storage and networking, attached as a read-only USB drive. "
                    + "In Setup, use Load driver and select viostor/w11/ARM64. Leave compatibility filtering on; do not use x64 drivers.",
                "• **Defaults**: 4 processors, 8 GiB memory (less on a small Mac), a 64 GiB sparse Virtio disk, NAT and a fixed "
                    + "1920 × 1200 display. Sound is off.",
                "The owner observed Windows startup and a started Virtio storage controller with an online target in the earlier "
                    + "standalone diagnostic. A completed Windows installation is not verified.",
                "The app supplies its own small EFI bootstrap because Apple's firmware display has no linear framebuffer. "
                    + "It uses a bounded RAM display, not graphics acceleration; resizing the window scales the picture, "
                    + "not the guest resolution.",
                "Before you start:",
            ] + WindowsRequirements.lines.map { "• " + $0 } + [
                "Older machines configured with NVMe must select Virtio in Storage before this boot path can start. "
                    + "Existing guest disks are never converted or reformatted automatically.",
                "Shared folders require a Windows virtio file-system driver. Disk snapshots work while stopped. "
                    + "Windows suspend is unavailable.",
            ],
            advanced: [
                "The boot path requires both checked private switches and the verified owned bootstrap/display. "
                    + "The standalone PMU guard remains: there is no automatic stock-firmware fallback and no extension "
                    + "to unverified host builds.",
                "Cold starts use a separate fresh firmware-variable store, leaving the original EFI store untouched. "
                    + "Custom persistent UEFI settings are not supported. The bootstrap selects an installed boot manager "
                    + "from disk before installer media and sets its own BootNext for normal guest reboots.",
                "The installer may ask you to press a boot key. Only you provide input. If Setup reports missing hardware "
                    + "or requirements, the app does not change what it checks. A boot failure or missing framebuffer stops "
                    + "with an error rather than trying the known-unsafe path.",
            ],
            related: [.privateInterfaces, .installerISO, .securityProfiles, .guestSystems, .limits]
        )
    ]
}
