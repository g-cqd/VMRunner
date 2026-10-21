extension HelpCatalog {
    static let machines: [HelpTopic: HelpEntry] = [
        .overview: HelpEntry(
            area: .start,
            title: "What VMRunner does",
            summary: "Runs macOS and Linux virtual machines on your Mac.",
            paragraphs: [
                "A virtual machine (VM) is a second computer running inside a window on your Mac. VMRunner lets you create one, install "
                    + "an operating system into it, and run it.",
                "• Click **+** (or press ⌘N) to create a machine. Pick macOS or Linux, give it a name and some resources, and press "
                    + "Create.",
                "• macOS needs a restore image (about 20 GB). Linux needs an installer ISO (from about 200 MB to a few GB).",
                "• When setup finishes, press **Start**. The first time, you go through the guest system's own installer or setup "
                    + "assistant.",
                "Everything you change in a machine's settings is saved immediately and takes effect the next time the machine starts.",
            ],
            advanced: [
                "VMRunner is a thin app on Apple's Virtualization framework. Machines live in "
                    + "`~/Library/Application Support/VMRunner/Machines/<id>.vm`. Nothing runs in the background when no machine is "
                    + "started."
            ],
            related: [.guestSystems, .setup, .controls]
        ),
        .guestSystems: HelpEntry(
            area: .start,
            title: "macOS or Linux guests",
            summary: "Only guests built for Apple silicon (arm64) can run.",
            paragraphs: [
                "The system inside a VM is called the **guest**; your Mac is the **host**.",
                "• **macOS guests** can be any macOS version your Mac supports, from Apple's restore images. At most two macOS VMs "
                    + "can run at "
                    + "the same time (an Apple limit).",
                "• **Linux guests** must be arm64 builds, such as CentOS Stream or Debian arm64. They boot through UEFI, like a real PC.",
                "• A 64-bit Intel (x86_64) operating system cannot run. It can only run Intel *programs* inside Linux, using Rosetta.",
            ],
            advanced: [
                "Windows is not supported by this app. For what the graphics can and cannot do, see Graphics and 3D acceleration."
            ],
            related: [.rosetta, .graphics, .limits]
        ),
        .macRestoreImage: HelpEntry(
            area: .start,
            title: "macOS restore image",
            summary: "The file that installs macOS into a new virtual machine.",
            paragraphs: [
                "Choose where it comes from:",
                "• **Latest supported**: the newest macOS this Mac can run, downloaded straight from Apple.",
                "• **ipsw.me**: a list of every macOS build Apple still signs. Pick an older version if you need one.",
                "• **Local .ipsw**: a file you already downloaded.",
                "A restore image is 20–27 GB. The download can be cancelled and resumes where it stopped. It is checked against a "
                    + "SHA-256 "
                    + "checksum before use. After a successful install it is deleted to save space (change this in Settings).",
            ],
            advanced: [
                "Restore images are universal (`UniversalMac_*`), so the Mac model you type for ipsw.me does not change the list. "
                    + "Downloads are limited to HTTPS from Apple and ipsw.me hosts. The checksum comes from ipsw.me, so it detects "
                    + "corruption, and the installer itself verifies Apple's signature."
            ],
            related: [.setup, .settings]
        ),
        .linuxImages: HelpEntry(
            area: .start,
            title: "Linux installation media",
            summary: "The ISO file that installs Linux. Pick a listed image or your own.",
            paragraphs: [
                "The list shows official images. The newest version is looked up when you press Create and downloaded from the "
                    + "project's own "
                    + "server.",
                "• A **boot ISO** is small and downloads the packages during installation, so the VM needs a network.",
                "• A **DVD** ISO is large but installs offline.",
                "• **Local ISO** lets you use any arm64 installer you already have.",
            ],
            advanced: [
                "Each download is checked against the checksum the project publishes next to the ISO. That proves the file arrived "
                    + "intact "
                    + "from that server; it does not prove who built it. Only HTTPS from a short list of project hosts is allowed."
            ],
            related: [.installerISO, .secureBoot]
        ),
        .setup: HelpEntry(
            area: .start,
            title: "Setting up a machine",
            summary: "Downloads the installer, creates the disk, and (for macOS) installs it.",
            paragraphs: [
                "After you press Create, the machine shows a progress bar while it downloads and verifies the installer, then creates "
                    + "its disk.",
                "• **Cancel** stops safely. Press **Resume Setup** later and the download continues from where it stopped.",
                "• If setup fails, the message says why. **Retry** runs it again.",
                "For Linux, setup ends with a ready machine that boots from the installer ISO. For macOS, setup also performs the "
                    + "install, "
                    + "which takes several minutes.",
            ],
            related: [.macRestoreImage, .linuxImages]
        ),
        .controls: HelpEntry(
            area: .machines,
            title: "Start, pause, suspend, shut down",
            summary: "Start boots the machine; the other buttons pause it, save it, or turn it off.",
            paragraphs: [
                "• **Start**: boots the machine (or resumes it if you suspended it).",
                "• **Pause**: freezes the machine in memory. It resumes instantly, but a pause is lost if you quit VMRunner.",
                "• **Suspend**: saves the machine's memory to disk and stops it. Start brings it back exactly as it was.",
                "• **Shut Down**: asks the guest to power off, like pressing a power button. A guest sitting in a boot menu or "
                    + "installer may ignore it.",
                "• **Force Stop**: cuts power immediately. Unsaved work in the guest is lost and its disk may need repair.",
            ],
            advanced: [
                "The Machine menu has the same actions with shortcuts. Quitting the app while a machine runs force-stops it after a "
                    + "confirmation."
            ],
            related: [.suspendResume, .shortcuts]
        ),
        .suspendResume: HelpEntry(
            area: .machines,
            title: "Suspend and resume",
            summary: "Saves the running machine to disk so it comes back exactly as it was.",
            paragraphs: [
                "Suspend writes everything in the machine's memory to a file and stops it. The next Start reads it back, and the "
                    + "saved file is "
                    + "then deleted. The file is about as large as the memory the guest was using.",
                "Suspend is **not available** when the machine is disposable or hardened, or when its devices don't support it. Hover "
                    + "over the "
                    + "greyed-out button to see why.",
                "Changing a hardware setting (CPU, memory, devices, display size, MAC address, Secure Boot) throws the saved state "
                    + "away, because it "
                    + "only fits the exact machine it was saved from. The next Start is then a normal boot.",
            ],
            advanced: [
                "The saved memory is not encrypted. Anything in the guest's RAM, including passwords, is on disk until you resume. "
                    + "VMRunner pins the MAC address and the starting display size so suspend and resume stay compatible."
            ],
            related: [.macAddress, .disposable, .securityProfiles]
        ),
        .runtimeLimit: HelpEntry(
            area: .machines,
            title: "Runtime limit",
            summary: "Automatically shuts the machine down after a set time.",
            paragraphs: [
                "Set a number of minutes and the machine is shut down when the time is up. A countdown shows in the toolbar.",
                "VMRunner first asks the guest to shut down politely. If the guest has not stopped after 30 seconds, it is "
                    + "force-stopped.",
                "The timer starts each time the machine starts or resumes. **Off** means no limit.",
                "Useful for throwaway test machines you don't want left running.",
            ],
            related: [.disposable, .securityProfiles]
        ),
        .duplicateDelete: HelpEntry(
            area: .machines,
            title: "Duplicate and delete",
            summary: "Duplicate makes an instant, space-saving copy. Delete removes a machine for good.",
            paragraphs: [
                "**Duplicate** creates an independent copy in a moment. It starts out using almost no extra disk space, because the "
                    + "copy shares "
                    + "data with the original until either one changes it. The copy gets its own identity (machine ID and MAC "
                    + "address). Saved "
                    + "memory state is not copied.",
                "A duplicate is much cheaper than installing again. For macOS, install once and duplicate.",
                "**Delete** permanently removes the machine and its disk. It is not available while the machine is running.",
            ],
            advanced: [
                "Duplicating uses APFS copy-on-write cloning, so the library must be on an APFS volume. The copy is built under a "
                    + "temporary "
                    + "name and renamed into place only when complete, so a failed duplicate never leaves a half-made machine."
            ],
            related: [.snapshots, .diskUsage]
        ),
        .diskUsage: HelpEntry(
            area: .machines,
            title: "Disk usage",
            summary: "How much space the machine's files take on your Mac.",
            paragraphs: [
                "The virtual disk is a *sparse* file: a 100 GB disk uses only the space the guest has actually written.",
                "The number shown counts data shared with duplicates and snapshots in full, so the real cost on your Mac is lower "
                    + "than shown.",
            ],
            related: [.diskSize, .snapshots]
        ),
    ]
}
