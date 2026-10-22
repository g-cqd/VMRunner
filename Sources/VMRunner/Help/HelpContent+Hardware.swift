extension HelpCatalog {
    static let hardware: [HelpTopic: HelpEntry] = [
        .cpuCores: HelpEntry(
            area: .compute,
            title: "CPU cores",
            summary: "How many processor cores the guest can use.",
            paragraphs: [
                "More cores help programs that can use them, but more is not always faster. Leave some cores for your Mac so "
                    + "everything stays responsive.",
                "A macOS guest needs at least what its restore image requires; VMRunner raises the number automatically if needed. "
                    + "The maximum is what your Mac offers.",
                "Takes effect the next time the machine starts.",
            ],
            related: [.memory]
        ),
        .memory: HelpEntry(
            area: .compute,
            title: "Memory",
            summary: "How much RAM the guest gets.",
            paragraphs: [
                "While the machine runs, this memory is taken from your Mac. If you give a VM too much, your Mac slows down.",
                "A rule of thumb: about 8 GB for a macOS guest and 2–4 GB for a small Linux server, and always leave plenty for your "
                    + "Mac itself.",
                "Takes effect the next time the machine starts.",
            ],
            advanced: [
                "Limits come from the Virtualization framework (a minimum, a maximum, and a size granularity). "
                    + "The memory balloon device lets a host ask a guest to give memory back, but VMRunner does not resize it "
                    + "automatically."
            ],
            related: [.cpuCores, .memoryBalloon]
        ),
        .nestedVirtualization: HelpEntry(
            area: .compute,
            title: "Nested virtualization",
            summary: "Lets the Linux guest run its own virtual machines and containers.",
            paragraphs: [
                "Turn this on if you want to run KVM, QEMU, or Podman/Docker with VMs *inside* the Linux guest. The guest then has a "
                    + "`/dev/kvm` device.",
                "It needs a Mac with an M3 chip or newer and macOS 15 or later. On other Macs the switch is disabled.",
                "Nested guests are slower, and a guest that can run its own hypervisor has more ways to attack the host. The "
                    + "Contained, Isolated, and "
                    + "Hardened profiles switch it off.",
            ],
            related: [.securityProfiles]
        ),
        .diskSize: HelpEntry(
            area: .storage,
            title: "Disk size",
            summary: "The size of the virtual disk. It can grow but never shrink.",
            paragraphs: [
                "The disk is a sparse file, so a large size costs nothing until the guest fills it.",
                "You can **grow** it (in steps of \(EditorLimits.diskStepGiB) GiB, up to \(EditorLimits.maxDiskGiB) GiB) but not "
                    + "shrink it. "
                    + "After growing, the guest still has to be told to use the new space.",
                "• **Linux**: grow the partition and filesystem (for example `growpart` then `resize2fs` or `xfs_growfs`).",
                "• **macOS**: use Disk Utility, or `diskutil apfs resizeContainer`.",
                "Growing a disk discards a suspended state.",
                "A new macOS machine needs at least \(EditorLimits.newMacDiskGiB.lowerBound) GiB: an install into 16 GiB failed.",
            ],
            advanced: [
                "The disk is a raw image (`Disk.img`). Raw sparse files stay small on APFS but don't return space when the guest "
                    + "deletes files."
            ],
            related: [.diskUsage, .snapshots]
        ),
        .diskCaching: HelpEntry(
            area: .storage,
            title: "Host caching",
            summary: "Whether your Mac caches the guest's disk in memory.",
            paragraphs: [
                "• **Automatic**: let macOS decide. A good default.",
                "• **Cached**: use your Mac's memory as a disk cache. Faster, and uses more host memory.",
                "• **Uncached**: skip the cache. Uses less host memory and behaves more predictably, but can be slower.",
            ],
            advanced: ["These map to the three disk image caching modes of the Virtualization framework."],
            related: [.diskSync]
        ),
        .diskSync: HelpEntry(
            area: .storage,
            title: "Flush behavior",
            summary: "How carefully the guest's disk writes are secured. Safest is slowest.",
            paragraphs: [
                "When a program in the guest says \"make sure this is really saved\", this setting decides what your Mac does.",
                "• **Full (safest)**: waits until the data reaches the physical drive. Best for anything you care about.",
                "• **fsync**: waits for the drive to accept it. Faster, with a small risk if power fails at the wrong moment.",
                "• **None (fastest)**: does not wait. If your Mac crashes or loses power, the guest's disk can be corrupted. "
                    + "Acceptable for throwaway test machines.",
            ],
            related: [.diskCaching, .disposable]
        ),
        .extraDisks: HelpEntry(
            area: .storage,
            title: "Extra disks",
            summary: "Attach more disk image files to the machine as additional drives.",
            paragraphs: [
                "Add a raw disk image and the guest sees a new, blank drive that it can format. Create an empty one in Terminal with "
                    + "`truncate -s 20g extra.img`.",
                "• Only **raw** images work (not qcow2 or vmdk).",
                "• Tick **Read-only** to stop the guest from changing it.",
                "• Never attach the same writable image to two running machines. They would corrupt it.",
                "Extra disks are **not** protected by Disposable mode: a writable extra disk keeps whatever the guest writes to it.",
                "A disk can't be a file inside VMRunner's own Machines folder, where other machines keep their disks.",
                "A disk you did not add yourself, for example in a machine copied from elsewhere, needs your approval at Start.",
            ],
            related: [.disposable]
        ),
        .installerISO: HelpEntry(
            area: .storage,
            title: "Installer ISO",
            summary: "The installation disc attached to a Linux machine.",
            paragraphs: [
                "The ISO is attached like a USB stick, so the machine boots from it on its first start.",
                "After Linux is installed, **untick \"Attach installer at boot\"** so the machine boots from its own disk. "
                    + "If you forget, you may see the installer again.",
                "**Change ISO** lets you swap in a different installer or rescue image.",
                "While it is attached, the guest can read the whole file, so only attach images you trust it to read. The Isolated "
                    + "and Hardened profiles detach it; ticking the box again makes the profile read **Custom**.",
            ],
            advanced: [
                "A downloaded installer is checked once, then copied into the machine's own folder as a copy-on-write clone, which "
                    + "shares disk space with the download. The machine boots from that copy, never from the shared download folder, "
                    + "so a later download or a damaged or replaced file there cannot change what it boots from. An ISO you choose "
                    + "yourself is used where it is."
            ],
            related: [.linuxImages, .securityProfiles]
        ),
        .graphics: HelpEntry(
            area: .display,
            title: "Graphics and 3D acceleration",
            summary: "macOS guests draw with your Mac's GPU; Linux guests do not get 3D acceleration.",
            paragraphs: [
                "• **macOS guests** use Apple's paravirtual graphics device, which draws with your Mac's GPU through Metal. "
                    + "The desktop and most apps are accelerated.",
                "• **Linux guests** get a plain virtual display. Apple's Virtualization framework offers no 3D acceleration for them, "
                    + "so the desktop and any OpenGL or Vulkan program are drawn by the CPU (software rendering). That is fine for servers "
                    + "and ordinary desktops, and slow for 3D games or heavy graphics work.",
                "Each machine has exactly one virtual screen; the framework does not support more.",
            ],
            advanced: [
                "GPU speed in macOS guests has not been benchmarked in this app. Hardware 3D for Linux would need a different "
                    + "virtualization stack, such as QEMU with virglrenderer or libkrun with Venus (Vulkan). They use Hypervisor.framework "
                    + "directly, so they cannot be switched on here. macOS 27 adds custom virtio devices that could in principle host a "
                    + "virtio-GPU implementation, but that is a research direction, not a feature."
            ],
            related: [.resolution, .guestSystems]
        ),
        .resolution: HelpEntry(
            area: .display,
            title: "Resolution",
            summary: "The size of the guest's screen. \"Match window\" is recommended.",
            paragraphs: [
                "• **Match window**: when the machine starts, the guest screen is sized to your window and keeps its shape. This "
                    + "keeps text readable.",
                "• **A preset or Custom size**: a fixed number of pixels. If your window has a different shape, the screen is shown "
                    + "with black bars.",
                "Why text can look tiny: boot menus (UEFI, GRUB) draw letters at a fixed pixel size. On a big window with a big "
                    + "screen, those "
                    + "letters become small. VMRunner therefore starts Linux at no more than 1280 pixels wide and scales it up. "
                    + "That holds for a preset or Custom size too, unless you also turn off \"Resize guest display with window\": "
                    + "then the guest keeps exactly the size you chose.",
                "A suspended machine resumes at the size it started with, whatever you change here. Discard the suspended state to "
                    + "use a new size.",
                "When the window changes size, VMRunner asks the guest for a new screen size. The guest may not use it, and the "
                    + "framework reports no error then. If the guest does not respond, the machine view says: "
                    + "\"\(DisplayFollower.ignoredNotice)\" The screen then keeps its size and is scaled to the window. A "
                    + "running guest follows only if its own display driver does.",
            ],
            advanced: [
                "\"Match window\" gives Linux 1 pixel per point (2 if you choose it) and macOS pixels-per-inch ÷ 72 pixels per point, "
                    + "limited to \(EditorLimits.displayWidth.lowerBound)–\(EditorLimits.displayWidth.upperBound) pixels wide. "
                    + "The size used at the last start is remembered so a suspended machine can resume."
            ],
            related: [.pixelDensity, .resizeWithWindow, .pixelsPerPoint, .linuxBootText]
        ),
        .pixelDensity: HelpEntry(
            area: .display,
            title: "Pixel density (macOS)",
            summary: "How sharp and how large macOS draws its interface.",
            paragraphs: [
                "This tells macOS how dense its screen is. **144** behaves like a Retina display: every interface element is drawn "
                    + "with twice "
                    + "as many pixels, so it looks sharp but fewer things fit on screen. **72** is a standard screen: smaller, less "
                    + "sharp, more room."
            ],
            related: [.resolution]
        ),
        .resizeWithWindow: HelpEntry(
            area: .display,
            title: "Resize guest display with window",
            summary: "Keeps the guest screen the same size as the window as you resize it.",
            paragraphs: [
                "When on, resizing the VMRunner window changes the guest's screen size to match, once the guest system is running. "
                    + "Boot menus before that cannot change size.",
                "When off, the guest keeps one fixed screen size and the picture is scaled to fit the window.",
                "A Linux text console (an installer, a server, a login prompt with no desktop) keeps the screen size it had when "
                    + "the system started: Linux draws its console on a buffer it makes once. When this setting is on and you "
                    + "resize the window, that console is then shown cropped or off-centre. For such a guest turn this setting "
                    + "off: the picture is then always whole, centred and scaled to the window. A desktop usually follows the "
                    + "window, because its display server changes the screen mode itself.",
            ],
            advanced: [
                "macOS guests use the framework's automatic resizing. Linux guests are resized by VMRunner itself at the chosen "
                    + "pixels per point, because the framework would hand them a Retina-scaled screen with tiny text. VMRunner "
                    + "leaves a Linux guest at its starting size for the first ten seconds after a cold boot, so the firmware reads "
                    + "the small size, and then asks for the window's size."
            ],
            related: [.pixelsPerPoint, .resolution]
        ),
        .pixelsPerPoint: HelpEntry(
            area: .display,
            title: "Guest pixels per point (Linux)",
            summary: "1× keeps text readable; 2× is sharper but looks small unless the guest scales it.",
            paragraphs: [
                "• **1×** gives the guest one pixel for each point of your window. Text looks normal-sized. Recommended.",
                "• **2×** gives the guest twice as many pixels. It is sharper on a Retina Mac, but a typical Linux desktop will draw "
                    + "tiny text "
                    + "unless you set its display scaling (for example 200% in GNOME).",
            ],
            related: [.resizeWithWindow]
        ),
        .linuxBootText: HelpEntry(
            area: .display,
            title: "Small text at boot (Linux)",
            summary: "Firmware and GRUB text is drawn before any driver loads; GRUB and console-font settings enlarge it.",
            paragraphs: [
                "Before Linux starts, the firmware and the boot loader (GRUB) draw their text on a plain screen, with no graphics driver "
                    + "and no acceleration. Their letters have a fixed size in pixels, so the more pixels the screen has, the smaller "
                    + "the text looks in your window.",
                "VMRunner starts a Linux guest at no more than 1280 pixels wide, in the shape of your window, and scales it up to the "
                    + "window. Once Linux runs, the guest follows the window. What happens inside the guest is up to the guest:",
                "• **GRUB**: in `/etc/default/grub` set `GRUB_GFXMODE=1280x800` (any size that `videoinfo` lists at the GRUB "
                    + "prompt; a smaller one draws larger letters) and `GRUB_GFXPAYLOAD_LINUX=keep` (the kernel keeps that mode) or "
                    + "`GRUB_GFXPAYLOAD_LINUX=text`. Then run `sudo update-grub` (Debian, Ubuntu) or "
                    + "`sudo grub-mkconfig -o /boot/grub/grub.cfg`.",
                "• **Console font**, after the kernel starts: add `fbcon=font:TER16x32` to `GRUB_CMDLINE_LINUX_DEFAULT` in the same "
                    + "file and run the same command. On Debian and Ubuntu you can instead set `FONTFACE=\"Terminus\"` and "
                    + "`FONTSIZE=\"16x32\"` in `/etc/default/console-setup` and run `sudo setupcon`.",
                "What cannot be done: the firmware's own screens and GRUB run before the guest has any driver, so nothing here can "
                    + "accelerate them or change the firmware's font. Linux guests get no 3D acceleration from Apple's framework at all.",
            ],
            advanced: [
                "The size the guest started with is recorded in the machine's `config.json` as `lastDisplayWidth` and "
                    + "`lastDisplayHeight`. These are guest settings: VMRunner cannot check them for your distribution, and whether the "
                    + "kernel offers `TER16x32` depends on how it was built. How the framework's firmware picks its screen mode is "
                    + "not documented, so the 1280 pixel start is a measure, not a guarantee."
            ],
            related: [.resolution, .resizeWithWindow, .graphics]
        ),
        .pointingDevice: HelpEntry(
            area: .display,
            title: "Pointing device (macOS)",
            summary: "Trackpad gives gestures and smooth scrolling; Mouse works with every guest.",
            paragraphs: [
                "• **Trackpad**: supports gestures and smooth scrolling. Needs a macOS 13 or newer guest.",
                "• **Mouse**: a plain pointer that works everywhere, including older macOS versions.",
                "Linux guests always use a mouse-style pointer.",
            ]
        ),
        .captureKeys: HelpEntry(
            area: .display,
            title: "Capture system keyboard shortcuts",
            summary: "Sends shortcuts like ⌘-Tab to the guest instead of your Mac while the VM has focus.",
            paragraphs: [
                "When on, keyboard shortcuts typed into the VM window go to the guest. That makes the guest feel like a real computer.",
                "The downside: your Mac's own shortcuts are sent to the guest too. For example ⌃⌘F (full screen) will not work while "
                    + "the VM has focus. "
                    + "Use the **View** and **Machine** menus instead.",
            ],
            related: [.fullScreen, .shortcuts]
        ),
        .inputResponsiveness: HelpEntry(
            area: .display,
            title: "Keep input responsive",
            summary: "Stops macOS from slowing the app while a machine runs, at a small cost in battery.",
            paragraphs: [
                "While a machine runs, the app asks macOS not to put it into App Nap and not to delay its timers. Without this, "
                    + "macOS may hold back an app it thinks is idle by a few milliseconds, which can feel like lag between a key press "
                    + "and the guest reacting.",
                "• **Cost**: the processor wakes more often and rests less deeply, so a Mac on battery uses somewhat more power "
                    + "while a machine runs. Your Mac still goes to sleep when idle, as usual.",
                "• **Where**: **Settings ▸ Keep input responsive while a machine runs**. It is on by default. Turn it off for a "
                    + "machine you leave running without using it.",
                "It cannot remove delay that comes from the guest, from your display's refresh rate or from Apple's virtualization "
                    + "framework.",
            ],
            advanced: [
                "The app holds one user-initiated, latency-critical activity (`ProcessInfo.beginActivity`) while at least one machine "
                    + "runs, and ends it when the last one stops. It does not use the option that keeps the Mac from sleeping when idle."
            ],
            related: [.settings, .pointingDevice, .captureKeys]
        ),
        .audio: HelpEntry(
            area: .display,
            title: "Sound output and microphone",
            summary: "Lets the guest play sound through your Mac and, optionally, record from your microphone.",
            paragraphs: [
                "• **Sound output** plays the guest's audio on your Mac's current output device.",
                "• **Microphone input** lets the guest listen through your Mac's microphone. macOS asks for permission the first time.",
                "The microphone is a channel from your room into the guest. Leave it off unless you need it.",
            ],
            related: [.securityProfiles]
        ),
    ]
}
