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
            related: [.suspendResume, .networkMode, .guestIdentity]
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
                "VMRunner only starts a machine with folders you chose in this app. If a machine you copied from elsewhere names "
                    + "folders, disks or an installer you did not choose, Start lists them and asks before it goes ahead.",
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
        .hostInformation: HelpEntry(
            area: .network,
            title: "Host information",
            summary: "Lets the guest read chosen facts about your Mac, such as its battery level or time zone. Off by default.",
            paragraphs: [
                "Some software in a guest behaves better when it knows about the Mac it runs on: a laptop on battery, a Mac "
                    + "that is running hot, a metered connection, or the local time zone. Turn on only what the guest needs: each "
                    + "fact is one more thing the guest learns about your Mac.",
                "• **Battery level**: the charge in percent (`none` on a Mac without a battery).",
                "• **Power source and Low Power Mode**: whether the Mac runs on its adapter or its battery, and whether Low "
                    + "Power Mode is on.",
                "• **Thermal state**: nominal, fair, serious or critical, as macOS reports it.",
                "• **Network path**: whether the Mac is online, over Wi-Fi, Ethernet or cellular, and whether the connection "
                    + "is metered or in Low Data Mode. No addresses or network names are shared.",
                "• **Time zone**: the Mac's time zone, such as `Europe/Paris`.",
                "The guest reads them as small text files in a read-only shared folder; nothing has to be installed in the "
                    + "guest. VMRunner writes them when the machine starts, every minute, and when your Mac's network changes.",
                "• **Linux**: `sudo mkdir -p /mnt/host && sudo mount -t virtiofs vmrunner-host /mnt/host`.",
                "• **macOS**: `mkdir ~/host && mount_virtiofs vmrunner-host ~/host`.",
                "The Isolated and Hardened profiles turn all of them off. Changes apply the next time the machine starts.",
            ],
            advanced: [
                "One file per fact, one `key=value` per line: `battery` (`percent=`), `power` (`source=ac`, `battery` or "
                    + "`unknown`, `lowPowerMode=0` or `1`), `thermal` (`state=`), `network` (`status=`, `interface=`, "
                    + "`expensive=`, `constrained=`) and `timezone` (`identifier=`). A fact that is off has no file. The "
                    + "folder is `HostInfo` in the machine's folder, emptied at every start.",
                "VMRunner rewrites each file in place. A program that reads one just as it is rewritten can find it empty. "
                    + "A file should not be missing (not yet verified in a guest): read it again a second later rather than take "
                    + "a missing file as a fact.",
                "The guest cannot write to the share. Reading it is still a channel from your Mac into the guest, so "
                    + "\"What this machine can reach\" lists it.",
            ],
            related: [.sharedFolders, .exposureSummary, .securityProfiles]
        ),
        .guestIdentity: HelpEntry(
            area: .security,
            title: "Guest identity",
            summary: "What the guest can learn about its virtual hardware, what you can change, and what it can always tell.",
            paragraphs: [
                "Software in a guest can read the identity of its virtual hardware: the network card's address, the disk's "
                    + "kind and serial number, the machine's identifier. These settings make that identity look less like a "
                    + "virtual machine's, or new at every start, for testing software that behaves differently in one, or for "
                    + "privacy.",
                "• **Network card vendor**: the first half of the MAC address names a manufacturer. *None* is what macOS "
                    + "makes for virtual machines, an address no manufacturer owns. Apple, Intel or Realtek make it look like "
                    + "one of their cards. It applies when VMRunner makes an address: clear the MAC address or press **Randomize**.",
                "• **Disk interface** (Linux): NVMe shows the disk as an NVMe drive instead of a virtio disk. A Linux system "
                    + "installed on virtio finds its disk under a new name; one that mounts its disks by UUID or label boots.",
                "• **Disk serial number**: what a virtio disk reports as its serial, at most 20 plain characters. An NVMe "
                    + "drive reports none.",
                "• **New identity at each start** (disposable machines): a new MAC address and machine identifier every time, "
                    + "so two runs cannot be matched by them. A macOS guest sees a new serial number each time. "
                    + "The fresh address is used for that run only; the machine's own address is not changed.",
                "**What a guest can still tell.** None of this hides the virtual machine from a guest that looks closely: a "
                    + "macOS guest is told by its kernel that it runs under a hypervisor and sees the virtual Mac model of its "
                    + "restore image; a Linux guest sees virtio devices and the firmware of Apple's virtualization; timing and "
                    + "the virtual processor give any guest away to a determined check. VMRunner cannot change these.",
                "These settings are for testing and privacy, not for getting around checks run by services you do not "
                    + "control.",
            ],
            advanced: [
                "The Apple, Intel and Realtek prefixes are 00:03:93, 00:1B:21 and 00:E0:4C. The disk serial is the virtio "
                    + "block device identifier. The identifier of a disposable start is kept beside the disposable disk and "
                    + "discarded with it.",
                "Not yet verified with a real guest: a macOS guest started with a new identifier, and a Linux guest moved "
                    + "to NVMe.",
            ],
            related: [.macAddress, .disposable, .exposureSummary]
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
                "• **Isolated**: Contained, and also no network, no shared folders, extra disks, attached installer image, "
                    + "driver disc or host information, and no "
                    + "sound. Linux gets Secure Boot if your Mac supports it and the machine's image can boot with it (Alpine "
                    + "cannot, so its Secure Boot stays off).",
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
                "A machine made from the Alpine Linux image keeps Secure Boot off: the switch is disabled with the reason, and "
                    + "no security profile turns it on. A machine made from your own ISO is not restricted, because VMRunner "
                    + "cannot tell what that image supports.",
            ],
            advanced: [
                "VMRunner enrolls Apple's platform key plus Microsoft's UEFI keys, so Microsoft-signed distribution loaders work. "
                    + "Turning the setting on or off discards a suspended state."
            ],
            related: [.securityProfiles, .linuxImages]
        ),
        .privateInterfaces: HelpEntry(
            area: .security,
            title: "Private interfaces",
            summary: "A few features use a framework switch Apple does not document. Strict profiles turn them off.",
            paragraphs: [
                "Apple documents what its virtualization framework can do. A few features need something it does not "
                    + "document. Windows on ARM needs **performance-monitoring emulation** and **fine-grained trap emulation**, "
                    + "together with the app's framebuffer bootstrap.",
                "The app reaches it through one checked path. Before each use it confirms that your Mac's macOS build is one "
                    + "the switch was tried on and that the framework still has it in the expected shape, then sets it and "
                    + "reads the value back. If any check fails, the feature stays off and the machine says why.",
                "A machine that uses a private interface cannot use it under the Isolated or Hardened profile, and your "
                    + "organisation can turn every private interface off with `AllowPrivateInterfaces`. A Windows machine needs "
                    + "both, so under any of these it does not start. \"What this machine "
                    + "can reach\" lists each one a machine would use.",
                "Because the switch is not documented, a macOS update can remove or change it, and an app that uses it cannot "
                    + "be offered on the Mac App Store.",
            ],
            advanced: [
                "A developer can turn every private interface off with a hidden default, `DisablePrivateInterfaces`, in the "
                    + "app's defaults domain (`defaults write` with the app's bundle identifier, the key and `-bool true`). It "
                    + "is read when a machine starts and is not a setting in the app; any value but an explicit false turns "
                    + "them off. Nothing here changes macOS or switches off any of its protections.",
                "The legacy diagnostic default `WindowsStartsWithoutPMU` accepts only an explicit true. It applies to "
                    + "standalone developer diagnostics, not the app's framebuffer-assisted boot path. It cannot relax that path's "
                    + "policy, bootstrap or read-back requirements and never switches a working emulation off.",
            ],
            related: [.securityProfiles, .exposureSummary, .managedSettings, .windowsMachines]
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
                "These are the memory balloon, the random-number generator, the host–guest socket, and the serial console. Each one is "
                    + "another thing the guest talks to, "
                    + "so each is a (small) part of the attack surface.",
                "A Linux guest can also be given the experimental custom GPU, a graphics device that VMRunner implements itself; it "
                    + "has its own topic.",
            ],
            related: [.memoryBalloon, .entropy, .vsock, .serialConsole, .customGPU]
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
            summary: "A private channel between the guest and your Mac, without a network; it can forward guest ports.",
            paragraphs: [
                "vsock lets a program in the guest talk to the app on your Mac without any network. Contained, Isolated, and Hardened "
                    + "turn it off to keep the surface small.",
                "A machine can forward guest vsock ports to your Mac: while it runs, each port in its vsockForwards list is served on "
                    + "a local socket (Vsock-22.sock for port 22, in the machine's folder, or in the console's private folder when "
                    + "that path is too long). A program on your Mac that connects to the socket is connected to the guest's port. "
                    + "Nothing is exposed to any network, and the guest's own traffic is untouched, so a machine on the filtered "
                    + "network can be reached this way while everything it sends leaves as your Mac's own traffic.",
                "The socket is yours alone (mode 0600, in a folder only you can enter), and \"What this machine can reach\" shows its "
                    + "path. Anyone who can connect reaches whatever listens on that port in the guest, so treat it like the console. "
                    + "The profiles that turn vsock off also empty the list.",
            ],
            advanced: [
                "A Linux guest with systemd 256 or later serves SSH on vsock port 22 by itself (sshd-vsock.socket, from "
                    + "systemd-ssh-generator). Add 22 to vsockForwards, then reach it with ssh -o ProxyCommand=\"nc -U <socket>\" "
                    + "<user>@<machine>, or put the ProxyCommand in a Host entry of ~/.ssh/config. The list is edited in the "
                    + "machine's config.json while VMRunner is closed."
            ],
            related: [.devices, .serialConsole]
        ),
        .serialConsole: HelpEntry(
            area: .security,
            title: "Serial console (local socket)",
            summary: "Lets a program on your Mac type into the Linux guest through a local socket. Off by default.",
            paragraphs: [
                "A serial console is a plain text connection between your Mac and the guest, like the console port of a server. "
                    + "VMRunner serves it on a local socket (a file on your Mac), so a terminal program or a script can log in to the "
                    + "guest and run commands without any network.",
                "Anyone who can reach the socket can type into the guest as whoever is logged in on its console, so treat it like a "
                    + "shell. The socket is yours alone (mode 0600, in a folder only you can enter), one program can be attached at "
                    + "a time, and nothing is exposed to the network. The Isolated and Hardened profiles turn it off. While it is "
                    + "on, \"What this machine can reach\" shows the socket's path.",
                "Nothing listens on the guest's side until you set it up:",
                "• **Any Linux**: add `console=hvc0` to the kernel command line. Alpine's init then starts a login on it by itself.",
                "• **Alpine from VMRunner's catalog**: its ISO boots with `console=tty0 console=ttyAMA0` after one second at its "
                    + "boot menu, so the socket stays silent. In that second press an arrow key in the machine's window, then `e`, "
                    + "add `console=hvc0` at the end of the line that starts with `linux`, and press Ctrl-X. VMRunner cannot change "
                    + "the ISO's command line for you; no image in the catalog is known to start a login on `hvc0` by itself.",
                "• **Distributions with systemd** (Debian, Ubuntu, Fedora, ...): run `systemctl enable --now serial-getty@hvc0` in "
                    + "the guest.",
                "• **macOS guests** are not supported: the switch is off and disabled for them.",
                "Takes effect the next time the machine starts.",
            ],
            advanced: [
                "The guest sees a virtio console port (`/dev/hvc0`). VMRunner joins it to a socket pair and copies bytes between the "
                    + "pair and the socket. It keeps the last 64 KiB of the guest's output for the next program that attaches, and it "
                    + "drops older output rather than ever holding the guest back. The socket is `Console.sock` in the machine's "
                    + "folder; when that path is too long for a local socket (about 100 bytes) it is a short name in a private "
                    + "folder of your temporary items instead.",
                "Attach with `nc -U <socket>`, or from a checkout of VMRunner with `swift run vmr guest console <socket>` "
                    + "(Ctrl-] detaches) and `swift run vmr guest exec <socket> -- <command>`.",
                "`nc` shows the guest's output as sent; `vmr guest console` filters it.",
            ],
            related: [.exposureSummary, .vsock, .devices, .securityProfiles]
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
