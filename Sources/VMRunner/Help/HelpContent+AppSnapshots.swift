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
                "• **Downloaded images**: shows how much space downloaded installers use, and lets you delete them. A machine "
                    + "made with this version keeps its own copy of its installer, so it is not affected. A machine made with an "
                    + "older version may still use a downloaded file; choose its installer again if that file is deleted.",
                "• **Default Mac model**: only used for the ipsw.me list, and has no effect on what you can install.",
                "• **Keep input responsive**: stops macOS from slowing the app while a machine runs, at some cost in battery. On by "
                    + "default.",
            ],
            related: [.macRestoreImage, .duplicateDelete, .inputResponsiveness, .managedSettings]
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
                "A machine that has not finished its setup, or is still being set up, is not started: the window says so in an "
                    + "alert, and the reason is in the system log.",
            ],
            advanced: [
                "`--input-latency` measures how late keyboard and mouse events reach the app and how long the main thread stays busy. "
                    + "Add `--input-latency-threshold-ms 1`, `--input-latency-interval 10` and `--input-latency-file /absolute/path` to "
                    + "change what counts as a stall, the seconds between summaries and where they are also written. The environment "
                    + "variables `VMR_INPUT_LATENCY`, `VMR_INPUT_LATENCY_THRESHOLD_MS`, `VMR_INPUT_LATENCY_INTERVAL` and "
                    + "`VMR_INPUT_LATENCY_FILE` do the same. Summaries also go to the system log, category `input`.",
                "`--display-diagnostics` logs each step that decides what the guest screen looks like: the size the guest starts "
                    + "with, every layout of the machine view, each request for a new size and its outcome, and the framework's own "
                    + "reconfiguration of the display. Only sizes and flags are logged. Read it with "
                    + "`log stream --level info --predicate 'category == \"display\"'`.",
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
        .managedSettings: HelpEntry(
            area: .app,
            title: "Settings your organisation manages",
            summary: "Settings your organisation set through a configuration profile. They are locked in the app.",
            paragraphs: [
                "An organisation can manage VMRunner with a configuration profile (managed preferences for the app). A "
                    + "setting it manages shows a lock and cannot be changed here; ask your administrator.",
                "For every machine:",
                "• `AllowSharedFolders`, `AllowClipboardSharing`, `AllowMicrophone`, `AllowSuspend` and `AllowHostInformation`: "
                    + "set to false, the feature is off on every machine and its control is locked.",
                "• `RequireDisposableMachines`: set to true, every machine is disposable.",
                "• `MaxRuntimeMinutes`: every machine stops after at most that many minutes (from 15 to 1440); 0 sets no limit.",
                "For the app itself, any of `hidesToolbarInFullScreen`, `keepsRestoreImages`, `holdsLatencyActivity` and "
                    + "`ipswDeviceIdentifier` can be set; the matching control is locked.",
                "A machine is brought within the policy when VMRunner loads it and whenever it changes, so it cannot start "
                    + "outside it.",
            ],
            advanced: [
                "Only values macOS reports as managed count: a value written with `defaults write` does not. A managed value "
                    + "of the wrong type restricts: an `Allow…` key that is not a Boolean turns the feature off, and a "
                    + "`MaxRuntimeMinutes` other than 0 that is not a whole number from 15 to 1440 becomes 15 (a Boolean false "
                    + "counts as not a number: 15).",
                "The policy is read from the app's own domain, also when `VMRUNNER_DATA_DIR` gives the settings a domain of "
                    + "their own. Machines are checked against the policy read at launch: quit and reopen VMRunner after a "
                    + "profile changes.",
                "Managed preferences govern this app only: a profile on your Mac does not reach inside a guest.",
            ],
            related: [.settings, .securityProfiles]
        ),
    ]
}
