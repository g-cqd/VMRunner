extension HelpCatalog {
    static let snapshotsAndApp: [HelpTopic: HelpEntry] = [
        .snapshots: HelpEntry(
            area: .snapshots,
            title: "Snapshots",
            summary: "Instant saved copies of a machine's disk that you can return to.",
            paragraphs: [
                "A snapshot records the disk as it is right now. If something goes wrong later, **Restore** puts the disk back.",
                "• Taking one is instant and costs almost no space. Space is only used for things that change afterwards.",
                "• The machine must be stopped, and not suspended. A snapshot holds the disk only, not what was in memory.",
                "• **Restore replaces the current disk.** Anything done since the snapshot is lost, so take a new snapshot first if "
                    + "you want it.",
            ],
            advanced: [
                "Snapshots are APFS copy-on-write clones of `Disk.img` and the firmware state under `Snapshots/` in the machine's "
                    + "folder. Restoring "
                    + "stages both clones before swapping either, and discards any suspended state."
            ],
            related: [.duplicateDelete, .disposable, .diskUsage]
        ),
        .settings: HelpEntry(
            area: .app,
            title: "Settings",
            summary: "App-wide options such as keeping downloaded restore images.",
            paragraphs: [
                "• **Keep macOS restore images**: by default the 20+ GB restore image is deleted after a successful install. Turn "
                    + "this on to keep it.",
                "• **Downloaded images**: shows how much space downloaded installers use, and lets you delete them. Machines are not "
                    + "affected.",
                "• **Default Mac model**: only used for the ipsw.me list, and has no effect on what you can install.",
                "• **Keep input responsive**: stops macOS from slowing the app while a machine runs, at some cost in battery. On by "
                    + "default.",
            ],
            related: [.macRestoreImage, .duplicateDelete, .inputResponsiveness]
        ),
        .shortcuts: HelpEntry(
            area: .app,
            title: "Menus and shortcuts",
            summary: "Everything the toolbar does is also in the Machine menu.",
            paragraphs: [
                "• New machine: **⌘N**",
                "• Start: **⌘R**",
                "• Pause / Resume: **⌥⌘P**",
                "• Suspend: **⌥⌘S**",
                "• Shut Down: **⌥⌘.**",
                "• Force Stop: **⇧⌥⌘.**",
                "If \"Capture system keyboard shortcuts\" is on, some of your Mac's shortcuts go to the guest while it has focus; the "
                    + "menus always work.",
            ],
            related: [.captureKeys, .fullScreen]
        ),
        .fullScreen: HelpEntry(
            area: .app,
            title: "Full screen",
            summary: "In full screen the guest fills the screen with no toolbar or sidebar.",
            paragraphs: [
                "Use **View ▸ Enter Full Screen**. While a machine runs, the toolbar and sidebar are hidden so the guest gets the "
                    + "whole screen. "
                    + "Use the Machine menu to control it.",
                "You can turn the hiding off with **View ▸ Hide Toolbar in Full Screen**.",
                "The keyboard shortcut ⌃⌘F is sent to the guest while the VM has focus (see Capture system keyboard shortcuts), so "
                    + "use the menu.",
            ],
            related: [.captureKeys, .shortcuts]
        ),
        .launchArguments: HelpEntry(
            area: .app,
            title: "Starting a machine from Terminal",
            summary: "Open the app with --start to boot a machine automatically.",
            paragraphs: [
                "From a script or Terminal:",
                "`open VMRunner.app --args --start \"Machine name\"`",
                "You can use the machine's name or its identifier. The window opens and the machine starts.",
            ],
            related: [.controls]
        ),
        .limits: HelpEntry(
            area: .app,
            title: "Limits and what is not included",
            summary: "What this app cannot do, and why.",
            paragraphs: [
                "• Only Apple silicon Macs, and only arm64 guests. An Intel operating system cannot run.",
                "• At most two macOS guests at once (an Apple limit).",
                "• No bridged networking and no USB device passthrough.",
                "• No Windows guests: Apple's framework has no supported way to run them.",
                "• Secure Boot needs macOS 27 or later on your Mac.",
                "• No 3D acceleration for Linux guests (software rendering); macOS guests use the GPU.",
                "• Suspend only works when the machine's devices support it, and the saved memory is not encrypted.",
            ],
            related: [.guestSystems, .networkMode, .secureBoot, .graphics]
        ),
    ]
}
