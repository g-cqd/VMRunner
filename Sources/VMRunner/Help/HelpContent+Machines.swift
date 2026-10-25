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
                "• **Linux guests** must be arm64 builds, such as CentOS Stream, Debian, Alpine, or Ubuntu arm64. "
                    + "They boot through UEFI, like a real PC.",
                "• A 64-bit Intel (x86_64) operating system cannot run. It can only run Intel *programs* inside Linux, using Rosetta.",
            ],
            advanced: [
                "Windows is not supported by this app. For what the graphics can and cannot do, see Graphics and 3D acceleration."
            ],
            related: [.rosetta, .graphics, .containers, .limits]
        ),
        .macRestoreImage: HelpEntry(
            area: .start,
            title: "macOS restore image",
            summary: "The file that installs macOS into a new virtual machine.",
            paragraphs: [
                "Choose where it comes from:",
                "• **Latest supported**: the newest macOS this Mac can run, downloaded straight from Apple. It is checked against "
                    + "the SHA-256 that ipsw.me lists for the same build. If ipsw.me cannot be reached or does not list the build, "
                    + "it is used without a checksum check.",
                "• **ipsw.me**: a list of every macOS build Apple still signs. Pick an older version if you need one. The download "
                    + "is checked against the SHA-256 that ipsw.me lists; a build listed without a valid checksum is left out.",
                "• **Local .ipsw**: a file you already downloaded. It is used as it is, with no checksum check.",
                "A restore image is 20–27 GB. The download can be cancelled and resumes where it stopped. A downloaded file that "
                    + "is already in the download folder is checked against its checksum again before it is reused, when it has one. "
                    + "After a successful install it is deleted to save space (change this in Settings).",
                "The system writes a download to a temporary file first, in the temporary folder, so that folder's volume needs as "
                    + "much free space as the image (about 19 GB for macOS).",
            ],
            advanced: [
                "Restore images are universal (`UniversalMac_*`), so the Mac model you type for ipsw.me does not change the list. "
                    + "A restore image downloads only over HTTPS from Apple's update server (updates.cdn-apple.com); ipsw.me is asked "
                    + "only for the list, and a build whose file is anywhere else is left out. The checksum comes from ipsw.me, "
                    + "so it detects corruption but not a substituted file served together with a matching checksum; the installer "
                    + "itself verifies Apple's signature. A download that grows past a size "
                    + "limit (48 GB) is stopped and its partial file deleted. A cancelled download is resumed only from partial data "
                    + "saved for the same address; any other is discarded."
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
                "The list offers CentOS Stream, Debian, Alpine Linux, Ubuntu Server (the current long-term-support release), "
                    + "AlmaLinux, Rocky Linux and Fedora Server.",
                "• A **boot ISO** is small and downloads the packages during installation, so the VM needs a network.",
                "• A **DVD** ISO is large but installs offline.",
                "• **Alpine Linux** is a small diskless system that runs from memory until you install it to disk. It does not "
                    + "support Secure Boot, so VMRunner keeps that off for it.",
                "• **Ubuntu Server** is a live-server ISO of about 3 GB that installs offline.",
                "Every download is checked against the checksum the project publishes. For **Ubuntu Server**, **Alpine Linux**, "
                    + "**AlmaLinux**, **Rocky Linux** and **Fedora Server**, the project's OpenPGP signature is checked too, against a "
                    + "key built into VMRunner; a missing or wrong signature stops the setup with a message. CentOS Stream and the "
                    + "Debian netboot image have no signature check, so only HTTPS from the project's own server protects them.",
                "• **Other ISO** lets you install from any arm64 installer you already have. It must boot with UEFI and support "
                    + "virtio disks and networking, which most current arm64 Linux distributions do. Other arm64 systems, "
                    + "such as the BSDs, may work too, but that has not been tested here.",
                "Windows is not supported: Apple's framework has no supported way to run it. See the Limits topic.",
            ],
            advanced: [
                "A checksum fetched from the same server proves the file arrived intact, not who built it. A valid signature proves "
                    + "that the holder of the project's key signed it: Ubuntu signs its SHA256SUMS list, AlmaLinux, Rocky Linux and "
                    + "Fedora sign their CHECKSUM lists and Alpine signs the ISO itself, "
                    + "and VMRunner checks each and refuses the download on any failure instead of falling back to the checksum alone.",
                "Alpine publishes each ISO before its signature. If the newest release has no signature yet, VMRunner uses the "
                    + "newest one that has, never older than the oldest it accepts, and says so while it sets up. It never installs an "
                    + "image without a valid signature, and any other problem with a signature stops the setup instead of trying an "
                    + "older release.",
                "The keys are built into the app with the date each one expires, if its vendor set one: from that date VMRunner "
                    + "refuses what the key signed until an app update pins the next key. VMRunner cannot see a key being revoked, "
                    + "and a new key needs an app update. A signature does not say the software is safe. Each image has an oldest "
                    + "release VMRunner accepts, "
                    + "so a genuine older signed file is refused; that limit rises with app updates. Only HTTPS from a short list "
                    + "of project hosts is allowed, and a download larger than a ceiling set for each image is stopped.",
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
        .containers: HelpEntry(
            area: .machines,
            title: "Containers",
            summary: "A container runs one command from an image in its own small Linux VM, started by a helper.",
            paragraphs: [
                "A container machine runs one program from a container image instead of a whole operating system. In the New "
                    + "Machine sheet choose **Container**, then give the image, optionally a command and some environment "
                    + "settings, and set its CPU cores, memory and network.",
                "• **Isolation.** Each container runs in its own lightweight Linux virtual machine, inside a separate helper "
                    + "process, **ContainerRunner**, bundled in the app. The helper is signed with the virtualization entitlement "
                    + "only and is not sandboxed. Do not treat that as the same protection as a virtual machine of this app.",
                "• **The image.** The helper pulls the image from its registry over the network when the container starts. An "
                    + "image is code from outside your Mac: run only images you trust.",
                "• **Network.** None, or loopback only: a network device that leads nowhere outside this Mac. There is no outside "
                    + "network yet, so the container cannot reach your network or the internet. This does not change the helper's "
                    + "own pull of the image.",
                "• **Working folder.** The folder `container-scratch` in the machine's folder keeps the kernel and the image cache "
                    + "the helper downloads. It is not removed automatically; deleting the machine removes it with the rest of the "
                    + "machine's folder.",
                "• **Output.** What the container prints is filtered before it is shown ("
                    + "the log removes control sequences and colour codes, and format characters) and bounded: the oldest output is "
                    + "dropped, with a note of how much.",
                "• **Stopping.** Stop sends the helper a stop line. If it has not ended after 10 seconds it gets SIGTERM, and "
                    + "after 5 more seconds SIGKILL. Quitting the app stops every running container.",
                "A container has no pause, suspend, snapshots or disk of its own, and this app's network policy, filtered "
                    + "network, shared folders and security profiles do not apply to it. **Allow agent access** works as for a "
                    + "virtual machine: a script with a control token can start and stop it.",
            ],
            advanced: [
                "The app starts `ContainerRunner <scratch> --json --image <reference> --cpus <n> --memory <MiB> --network "
                    + "<none|loopback>`, then one `--env NAME=value` per environment setting and one `--command <word>` per word "
                    + "of the command, without a shell. The scratch folder has mode 0700. The runner reports phases, output and "
                    + "its exit status as JSON lines.",
                "Limits: an image reference up to 255 bytes without whitespace; 1 to 16 CPU cores; 128 to 16384 MiB of memory; "
                    + "up to 64 command words of up to 4096 bytes each; up to 64 environment settings, each name once. The "
                    + "log keeps the most recent 1 MiB of output.",
                "While a container's helper runs, the app holds a user-initiated activity (not latency-critical, so the Mac "
                    + "still sleeps when it is idle), so that macOS does not slow the app down and delay the stop's time limits.",
                "An organisation can forbid containers with the managed setting `AllowContainers` set to false: the New "
                    + "Machine sheet then offers no Container kind, a container machine does not start, and its settings are "
                    + "locked.",
            ],
            related: [.agentAccess, .managedSettings, .guestSystems]
        ),
    ]
}
