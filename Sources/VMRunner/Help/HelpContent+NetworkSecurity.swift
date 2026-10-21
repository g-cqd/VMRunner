extension HelpCatalog {
    static let networkAndSecurity: [HelpTopic: HelpEntry] = [
        .networkMode: HelpEntry(
            area: .network,
            title: "Network mode",
            summary: "NAT shares your Mac's connection; Filtered adds rules you control; None gives the guest no network.",
            paragraphs: [
                "• **NAT**: the guest gets a private address and reaches the internet (and your local network) through your Mac, using "
                    + "whatever connection your Mac uses. Nothing outside can start a connection to the guest. The guest can usually "
                    + "reach "
                    + "services your Mac offers on the NAT gateway address.",
                "• **Filtered (user-mode)**: like NAT, but VMRunner checks every connection against rules you write (allow-lists, "
                    + "block-lists, ports, domains) and shows what the guest tried. It is new and less proven than NAT; see "
                    + "*Filtered network and policy*.",
                "• **None**: the guest has no network device. Use this for an air-gapped machine.",
                "Bridged networking (putting the guest directly on your LAN) is not offered, because it needs a special Apple "
                    + "entitlement "
                    + "that apps signed without a paid developer certificate cannot have.",
            ],
            advanced: [
                "NAT is Apple's vmnet shared network. The guest's traffic follows your Mac's routing, but some VPN clients do not "
                    + "capture it, "
                    + "so do not assume a host VPN protects the guest."
            ],
            related: [.networkPolicy, .macAddress, .securityProfiles]
        ),
        .macAddress: HelpEntry(
            area: .network,
            title: "MAC address",
            summary: "The guest network card's hardware address. Leave it on automatic.",
            paragraphs: [
                "Each VM gets its own address the first time it starts, and keeps it. Keeping it fixed matters: the guest's network "
                    + "settings "
                    + "and a suspended state both depend on it.",
                "Type your own only if you need a stable address, for example for a router's DHCP reservation. Press **Randomize** to "
                    + "make a new one. "
                    + "Changing it discards a suspended state.",
            ],
            related: [.suspendResume, .networkMode]
        ),
        .sharedFolders: HelpEntry(
            area: .network,
            title: "Shared folders",
            summary: "Makes folders from your Mac available inside the guest.",
            paragraphs: [
                "Add a folder and the guest can open it like a drive.",
                "• **macOS guests**: it appears automatically under `/Volumes/My Shared Files`.",
                "• **Linux guests**: mount it yourself with `sudo mount -t virtiofs share /mnt`.",
                "• Tick **Read-only** to let the guest look but not change anything. Do this unless the guest must write.",
                "A writable shared folder is the biggest door between guest and Mac: software in the guest can change or delete "
                    + "everything in it.",
            ],
            advanced: [
                "Sharing uses virtio-fs. Several folders are exposed under one share, each as a sub-folder named after the original "
                    + "folder."
            ],
            related: [.securityProfiles, .exposureSummary]
        ),
        .clipboard: HelpEntry(
            area: .network,
            title: "Share clipboard (Linux)",
            summary: "Copy and paste text between your Mac and the Linux guest.",
            paragraphs: [
                "Needs the `spice-vdagent` package running inside the guest (install it with your distribution's package manager).",
                "Anything you copy on either side can be read by the other, so turn it off for machines you don't trust.",
            ],
            related: [.securityProfiles]
        ),
        .rosetta: HelpEntry(
            area: .network,
            title: "Rosetta for Intel programs (Linux)",
            summary: "Runs Intel (x86_64) Linux programs inside the arm64 guest.",
            paragraphs: [
                "Apple's Rosetta can translate Intel Linux programs so they run in your arm64 Linux guest. It does not make an Intel "
                    + "*operating system* run.",
                "If Rosetta isn't installed yet, press **Install Rosetta**. Then, inside the guest, mount the share it creates and "
                    + "register it:",
                "• `sudo mount -t virtiofs rosetta /media/rosetta`",
                "• register `/media/rosetta/rosetta` with `binfmt_misc` for x86_64 binaries (your distribution's documentation "
                    + "explains how).",
            ],
            related: [.guestSystems]
        ),
        .securityProfiles: HelpEntry(
            area: .security,
            title: "Security profiles",
            summary: "One-click presets for how much of your Mac the guest can reach.",
            paragraphs: [
                "A profile sets many switches at once. You can still change any switch afterwards; the profile then shows **Custom**.",
                "• **Standard**: normal use. NAT network, clipboard, sound, and the folders you share.",
                "• **Contained**: keeps the network but closes the side doors: no clipboard, microphone, Rosetta, nested "
                    + "virtualization, or vsock, "
                    + "and shared folders become read-only.",
                "• **Isolated**: Contained, and also no network, no shared folders or extra disks, and no sound. Linux gets Secure "
                    + "Boot if your Mac supports it.",
                "• **Hardened**: Isolated, and also disposable (changes are discarded), no suspend, no memory balloon, no automatic "
                    + "login or "
                    + "remote login on a new macOS account, and a 2-hour runtime limit.",
                "These settings narrow the ways the guest and your Mac can talk. They do not make an untrusted guest safe on their "
                    + "own: keep "
                    + "your Mac updated and be careful what you run.",
            ],
            advanced: [
                "The random-number device is never removed because the guest needs it. Profiles only set what they define, so your own "
                    + "choices (such as nested virtualization) stay unless the profile closes them."
            ],
            related: [.exposureSummary, .disposable, .secureBoot]
        ),
        .disposable: HelpEntry(
            area: .security,
            title: "Disposable machine",
            summary: "Throws away everything the guest changes when it stops.",
            paragraphs: [
                "Each start uses a fresh, instant copy of the disk. When the machine stops, the copy is deleted, so the next start is "
                    + "exactly "
                    + "like the first. Great for testing risky software or running repeatable jobs.",
                "• Nothing is kept: files, settings, and installed programs are all lost, including anything you want to keep. Save work "
                    + "to a shared folder first.",
                "• Suspend is turned off.",
                "• **Extra disks are not disposable.** A writable extra disk keeps what the guest writes to it.",
            ],
            advanced: [
                "The disk and the firmware state (macOS auxiliary storage or Linux UEFI variables) are copy-on-write clones made at "
                    + "start and "
                    + "removed at stop. Leftovers from a crash are removed the next time the app launches. Needs the library on an "
                    + "APFS volume."
            ],
            related: [.snapshots, .securityProfiles, .extraDisks]
        ),
        .secureBoot: HelpEntry(
            area: .security,
            title: "Secure Boot (Linux)",
            summary: "Only lets properly signed bootloaders and kernels start.",
            paragraphs: [
                "With Secure Boot on, the guest refuses to boot software that isn't signed by a trusted key. That blocks tampered "
                    + "boot files.",
                "It needs a Mac running macOS 27 or later; on older versions the switch is disabled. Debian, CentOS, Fedora, and "
                    + "Ubuntu ship "
                    + "signed boot files. Custom kernels and some small distributions (for example Alpine) will not start.",
            ],
            advanced: [
                "VMRunner enrolls Apple's platform key plus Microsoft's UEFI keys, so Microsoft-signed distribution loaders work. "
                    + "Turning the setting on or off discards a suspended state."
            ],
            related: [.securityProfiles, .linuxImages]
        ),
        .exposureSummary: HelpEntry(
            area: .security,
            title: "What this machine can reach",
            summary: "A list of the ways the guest can interact with your Mac, ranked by risk.",
            paragraphs: [
                "Each line is one door between the guest and your Mac, and the dot shows how risky it is:",
                "• **Green**: closed or harmless.",
                "• **Yellow / orange**: open, with limited reach.",
                "• **Red**: the guest can change your files.",
                "Use it to check a machine before you run something you don't trust. It lists what is configured; it is not a "
                    + "guarantee that "
                    + "the guest software is safe.",
            ],
            related: [.securityProfiles]
        ),
        .devices: HelpEntry(
            area: .security,
            title: "Virtual devices",
            summary: "Small helper devices the guest can use. Most people never change them.",
            paragraphs: [
                "These are the memory balloon, the random-number generator, and the host–guest socket. Each one is another thing the "
                    + "guest talks to, "
                    + "so each is a (small) part of the attack surface."
            ],
            related: [.memoryBalloon, .entropy, .vsock]
        ),
        .memoryBalloon: HelpEntry(
            area: .security,
            title: "Memory balloon",
            summary: "A device that lets the host ask the guest to give memory back.",
            paragraphs: [
                "Harmless and on by default. VMRunner doesn't resize the balloon on its own today, so it has no visible effect. Safe "
                    + "to turn off."
            ],
            related: [.memory, .devices]
        ),
        .entropy: HelpEntry(
            area: .security,
            title: "Entropy (random numbers)",
            summary: "Gives the guest good random numbers from your Mac. Leave it on.",
            paragraphs: [
                "Programs in the guest need unpredictable numbers for encryption keys and secure connections. Turning this off can make "
                    + "the guest's cryptography weaker, so no security profile turns it off."
            ],
            related: [.devices]
        ),
        .vsock: HelpEntry(
            area: .security,
            title: "Host–guest socket (vsock)",
            summary: "A private channel between the guest and VMRunner. Nothing uses it yet.",
            paragraphs: [
                "vsock lets a program in the guest talk to the app on your Mac without any network. VMRunner doesn't listen on it today, "
                    + "so leaving it on or off changes nothing you can see. Contained, Isolated, and Hardened turn it off to keep the "
                    + "surface small."
            ],
            related: [.devices]
        ),
        .bootRecovery: HelpEntry(
            area: .macOS,
            title: "Start in macOS Recovery",
            summary: "Boots the macOS guest into its Recovery environment instead of normal macOS.",
            paragraphs: [
                "Use it to reinstall macOS, repair the disk, or change system security settings inside the guest.",
                "The setting stays on until you untick it, so untick it again when you are done. It is turned off by the security "
                    + "profiles.",
            ]
        ),
        .firstBootAccount: HelpEntry(
            area: .macOS,
            title: "First-boot account (macOS 27 guests)",
            summary: "Creates the user account for you so you can skip the Setup Assistant.",
            paragraphs: [
                "Fill in a name, a user name, and a password, and the guest creates that account the first time it starts after "
                    + "installation.",
                "• It only works with a **macOS 27 or later** guest. Older versions ignore it.",
                "• The password is kept in memory only and is never saved to disk. If you quit VMRunner before the first start, type "
                    + "it again.",
                "• It is used once. Disposable machines and Recovery boots do not use it up.",
                "Automatic login and remote login (SSH) widen who can get into the guest. Turn them off if you don't need them.",
            ],
            related: [.bootRecovery, .securityProfiles]
        ),
    ]
}
