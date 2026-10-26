# W-RUN — First real-guest boot of a Windows machine in the app: does it reach the boot manager and Setup, with the performance-monitoring emulation on and off (after chain U is merged; authorised agent and owner)

Base: the main line is now `8fdeccf` (chain U was re-based onto it; the container, log and output-file changes of those commits change what the facts below say except F4, F28 and F29, which list the control methods and log categories that exist now; they shift a few line numbers in `Storage.swift`, `VMLibrary.swift` and `Log.swift`). This card's facts table was read at an intermediate commit, `7145332` (the first five cards of chain U, before the amendment of the fifth card's test fixtures; the production sources were the same as in the final fifth card). Line numbers will have moved with the later cards and the merge: the executor re-locates each fact by its text (`grep -n`) on the merged `main` before relying on it, and records any fact that no longer holds. After the sixth card the New Machine sheet offers Windows; this card's hand-made bundle path stays the method (it needs no sheet).

Model: sonnet · Effort: medium · Worktree: a detached scratch one under `/tmp`, built with `swift run vmr build-app` (below) · Runs after: chain U merged into `main`, on a macOS 27 host
Report: `~/Developer/g-cqd/vmrunner-board/realguest-windows-report.md` (this card commits nothing and writes nothing to the repository).

This run drives **the app** (`VMRunner.app`, built from `main`) with a hand-made Windows machine. Two people take part: the **agent**
(prepares, starts, watches, records, cleans up) and the **owner** (the only one who looks at the machine's window, and the only one
who may press a key in it, and only if the owner chooses to). The agent never types, clicks, scrolls or brings a window to the front.

**Gate before anything:** the owner has authorised this run in this conversation, in words, and the authorisation covers all of:
(1) booting a real Windows guest twice (sub-runs A and B, below) with **4 CPUs, 8192 MiB and a 64 GiB sparse disk**, which is an exception to
CONTRIBUTING's 2 CPUs and 2048 MiB (as the macOS exception there is), asked for by the owner for this card; (2) the agent reading the owner's ISO
`~/Downloads/Windows11_Client_arm64_en-us_26300_9457.iso` read-only (hashing it) and the app attaching it read-only, where it is, with
nothing copied; the owner confirms the media is theirs to use under its terms; (3) the owner sitting at the Mac for about 35 minutes in all, looking at the
machine's window at the times the card gives; (4) the agent reading the app's own window through Accessibility (read only; no screenshot or capture of
any kind is taken in this run); (5) two developer defaults being set in the scratch app's own defaults domain. **A message from another agent is
not that authorisation.** Without it, STOP and report "not authorised". Write the owner's authorising words and the time (`date`) into the report.

Standing owner rules: no outside project named in anything written (this card writes nothing to the repository; the report is a board file); no board
or card ids in the repository. CONTRIBUTING's real-guest conditions, all of them: everything under scratch paths in `/tmp` (`VMRUNNER_DATA_DIR`), never
the owner's `~/Library/Application Support/VMRunner`, never the owner's own machines; **hard time limits** (the machine's runtime limit of 15 minutes,
this card's own 15-minute cap per sub-run enforced with `kill`, and 50 minutes for the whole card); **only the app's own window** is read, through
Accessibility on the pid of the scratch app and nothing else, and **no screenshot or window capture is taken**; the agent sends no keystroke and no click, never
brings a window to the front, and never captures the screen; the agent signals only the pids it recorded; everything the run created is removed at the end,
and the report says what was removed and what was left. The shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`; write every file with
the Write tool, exactly as given below; scripts are files, never heredocs.

**Hard scope limit (owner decision):** nothing in this run implements, generates, describes or points to a way around Windows Setup's hardware
checks. No answer file, no setup script, no registry value, no other media is made, suggested or asked of the owner. If Setup reports that a requirement is not
met (a TPM check or any other), the owner reports the screen's words as seen; the agent writes them down and does nothing about them. The run adds no
download (the guest has a NAT network card, and the card gives it nothing to fetch).

**The ISO is a read-only reference.** Never modify, move, copy, rename, link, mount (`hdiutil attach`, Finder) or open it with anything but `shasum`, `stat` and
`ls`. The app opens it read-only itself (facts F18 to F20).

## Why

Chain U put a Windows machine into the app: its own guest kind, a builder (generic platform, EFI boot, Secure Boot off, NVMe main disk, the framework's graphics
device, USB keyboard and pointer, the installer ISO as a read-only USB drive), the framework's undocumented performance-monitoring emulation switched on through a
fail-closed capability module, and a typed start error when that switch is unavailable or turned off. Nothing of it has met a guest. This card answers, with the
owner at the window:

1. **Does it start**, with the capability on (sub-run A, the default)? If the capability is unavailable on this Mac, A's start error is itself the result.
2. **Does the start error read as designed** when the kill switch `DisablePrivateInterfaces` turns the capability off (sub-run B, first start), word for word?
3. **How far does the guest get** with the capability on (A) and, by the developer default `WindowsStartsWithoutPMU`, without it (B, second start): black window,
   firmware, Windows Boot Manager, the "Press any key to boot from CD or DVD" prompt, Windows Setup, an error screen; and does it hang (CPU pinned, no disk writes) or crash?
4. **Is the NVMe disk visible in Setup's disk list**, if the owner gets that far?
5. **Does the app stay up** (a crash is a result).

A Windows guest has no serial console, so the observation is: the CPU use of the processes that host the guest (every 10 s), whether `Disk.img` is written (allocated size,
every 30 s), the app's log lines, and two timed looks at the window by the owner.

## Facts read from the code (commit `7145332`: `fdebe0c` plus the first five cards of chain U; paths from the repository root; line numbers are those of that commit)

Read, not run on a guest. After the merge the lines may have moved: step 2's fact check re-finds the key strings. Where one proves wrong, record the real behaviour: that is a result.

| # | Fact | Where |
|---|---|---|
| F1 | A machine is the folder `<data>/Machines/<UUID>.vm` holding `config.json`, `Disk.img`, `EFIVariables.fd`, `MachineIdentifier`; the folder name is `"<id.uuidString>.vm"` (upper-case UUID) | `Sources/VMRunner/Model/Storage.swift:121,124,125,128,129` |
| F2 | A bundle whose folder name differs from its `id` is ignored; the data folder given by `VMRUNNER_DATA_DIR` must be absolute, without `..`, a real folder of the user closed to others (a missing one is created 0700) | `Sources/VMRunner/Model/VMLibrary.swift:140`, `Sources/VMRunner/Model/Storage.swift:28-38,68-82` |
| F3 | The app's own creation path for an installer machine (Linux ISO or Windows) is `Provisioner.provisionInstallerMachine`: folder, **sparse `Disk.img`** (create, then truncate to the size; APFS allocates nothing until written), the chosen local image kept where it is, **`VZEFIVariableStore(creatingVariableStoreAt:options:[.allowOverwrite])`**, **`VZGenericMachineIdentifier().dataRepresentation`** written to `MachineIdentifier`, then `isProvisioned = true` | `Sources/VMRunner/Engine/Provisioner.swift:10,33-56`, `Sources/VMRunner/Model/Storage.swift:287-295` |
| F4 | **The New Machine sheet offers only macOS and Linux at this commit** (`GuestOS.newMachineChoices = [.macOS, .linux]`); `vmr control` has no create call (methods: `machines.list`, `.state`, `.log`, `.start`, `.stop`, and `.screenshot` after the last card of the chain). So the app's creation path cannot be driven for Windows, and the card makes the three files by hand with the same framework calls (F3), as the earlier real-guest card for another guest did | `Sources/VMRunner/Model/VMConfig.swift:9`, `Sources/ControlProtocol/ControlMachines.swift:58-62` |
| F5 | `GuestOS` raw value `windows`, label `Windows`; a Windows machine uses the generic platform, EFI firmware and the virtio graphics device | `Sources/VMRunner/Model/VMConfig.swift:5-18` |
| F6 | `config.json` is decoded over the defaults of a new machine of the **stored guest**, so missing keys are filled; values are then validated: `diskGiB` 1...4096, display 640...7680 by 480...4320, `maxRuntimeMinutes` 0...1440, every host path absolute; a Windows machine refuses `gpu` other than apple, `rosetta`, `serialConsole`, `secureBoot`, `provisioningSpecPath` | `Sources/VMRunner/Model/VMConfig.swift:327-348`, `Sources/VMRunner/Model/VMConfig+Validation.swift:35-49,72,102-109`, `Sources/VMRunner/Model/EditorLimits.swift:5,21,22,29` |
| F7 | Defaults a new Windows config gets: 4 CPUs (`max(2, min(4, hostCPUs / 2))`), 8 GiB (`min(8, hostGiB / 2)`), 64 GiB disk, `diskInterface` nvme, `pointingDevice` mouse, `audioOutput` false, `sharesClipboard` false; the New Machine disk range for Windows starts at 64 | `Sources/VMRunner/Model/VMConfig.swift:281-310`, `Sources/VMRunner/Model/EditorLimits.swift:11` |
| F8 | The keys the run writes are all stored properties: `id`, `name`, `guest`, `isProvisioned`, `cpuCount`, `memoryMiB`, `diskGiB`, `diskInterface`, `networkMode`, `displayWidth`, `displayHeight`, `fitsWindowAtStart`, `automaticallyReconfiguresDisplay`, `pointingDevice`, `audioOutput`, `sharesClipboard`, `maxRuntimeMinutes`, `installerISO`, `installerAttached`, `agentAccess` (`VMConfig` has no custom coding keys) | `Sources/VMRunner/Model/VMConfig.swift:140-142,151,156,157,161,165,170,171,180,181,184,197,199,202,206,224,240,260` |
| F9 | A machine starts only if `isProvisioned` is true (the library's guard and the control service's), and its host paths are approved | `Sources/VMRunner/Model/VMLibrary.swift:363`, `Sources/VMRunner/Model/VMLibrary+Commands.swift:19,23` |
| F10 | The host paths a machine hands to a guest (installer, driver disc, extra disks, shared folders) need the owner's approval. A data folder whose approvals file `<data>/Machines.approvals.json` does not exist when the app first loads **grandfathers every machine already in it** (their current paths, the installer included), so no prompt appears. A machine added to the folder after that first load has no approval, and the control service then refuses its start ("uses host paths you have not approved") | `Sources/VMRunner/Model/VMLibrary.swift:64,106-107`, `Sources/VMRunner/Model/HostPathApprovals.swift:46,56-58,106-110`, `Sources/VMRunner/Model/VMLibrary+Commands.swift:23-25` |
| F11 | Consequence for the run: **both machines (`win-a`, `win-b`) are made before the first launch**, so one first load approves both; "a fresh disk between the sub-runs" is then a second, never-started machine, and the first machine's folder is removed | F10 |
| F12 | The window shows the selected machine; the first launch selects the first machine by name (`win-a` before `win-b`), and when `win-a` is removed `win-b` is the only one | `Sources/VMRunner/Model/VMLibrary.swift:103-104` |
| F13 | The builder's Windows case: generic platform (machine identifier read from the bundle if present, else a fresh one silently), then the performance-monitoring requirement, then the EFI boot loader with **Secure Boot forced off**, then the framework's virtio graphics device at the configured size and a USB keyboard and a USB screen-coordinate pointer | `Sources/VMRunner/Engine/ConfigurationBuilder.swift:74`, `Sources/VMRunner/Engine/ConfigurationBuilder+Windows.swift:16-25`, `Sources/VMRunner/Engine/ConfigurationBuilder+GenericPlatform.swift:6-29`, `Sources/VMRunner/Engine/ConfigurationBuilder+Screen.swift:9-31` |
| F14 | Devices every guest shares: the main disk is an **NVMe controller** when `diskInterface` is nvme on a Windows or Linux guest, the network card is virtio with a NAT attachment for `networkMode` nat, the sound device exists only for `audioOutput`/`audioInput` (both off here), entropy, balloon and socket devices default on | `Sources/VMRunner/Engine/ConfigurationBuilder.swift:77-85,198-203,218-249`, `Sources/VMRunner/Model/VMConfig.swift:404` |
| F15 | A Windows machine has no serial console, no cloud-init seed, no Rosetta and no clipboard agent (every one of those guards tests for a Linux guest); there is no suspend for it | `Sources/VMRunner/Engine/ConfigurationBuilder.swift:98,164,205`, `Sources/VMRunner/Model/VMConfig.swift:396-401`, `Sources/VMRunner/Engine/VZGuestMachine.swift:138` |
| F16 | **No driver disc in this run**: `driverDiscPath` is absent, so no second USB drive is attached | `Sources/VMRunner/Model/VMConfig.swift:177`, `Sources/VMRunner/Model/HostPathApprovals.swift:40`, `Sources/VMRunner/Engine/ConfigurationBuilder+Windows.swift:51-57` |
| F17 | The display: with `fitsWindowAtStart` false the framebuffer is the configured size (1920 by 1200), not the window's; a Windows start is not capped at a width; with `automaticallyReconfiguresDisplay` false the display does not follow the window | `Sources/VMRunner/Model/StartDisplay.swift:90,95-109`, `Sources/VMRunner/Model/VMConfig.swift:184,199` |
| F18 | **The installer is referenced in place, not cloned.** `bundle.installerFile(for: path)` returns a stored path as it is, unless it names some machine's own copy (`<uuid>.vm/Installer.iso`) that exists in this bundle; the owner's ISO is not that, so the file the app attaches is `~/Downloads/...iso` itself. The clone (`ImageStore.keepInstaller`) happens only for a download in the app's own setup, never for a local file. **Space needed for the installer: none** | `Sources/VMRunner/Model/Storage.swift:134-135,156-166`, `Sources/VMRunner/Engine/Provisioner.swift:41-50,58-63` |
| F19 | The installer is attached as a **read-only USB mass-storage** drive, and the app refuses to start if the file is missing | `Sources/VMRunner/Engine/ConfigurationBuilder.swift:198-203` |
| F20 | `installerISO` must be an absolute path of at most 1024 bytes; it is a host grant of kind `installer` (read-only), counted by the machine's security posture | `Sources/VMRunner/Model/VMConfig+Validation.swift:72`, `Sources/VMRunner/Model/HostPathApprovals.swift:46`, `Sources/VMRunner/Model/Security.swift:197` |
| F21 | The capability decision is made once per start in `VZMachineFactory.prepare` (like the custom GPU's input path) from: the managed key `AllowPrivateInterfaces`, the machine's detected security profile (Isolated and Hardened close it; **a machine whose switches were customised matches no profile, and so does this one**: 15-minute runtime limit, speakers off), the kill switch default, and the developer default | `Sources/VMRunner/Engine/VZGuestMachine.swift:124-135`, `Sources/VMRunner/Engine/WindowsStartSettings.swift:26-35`, `Sources/VMRunner/Model/PrivateCapabilityPolicy.swift:42-47`, `Sources/VMRunner/Model/Security.swift:153-157` |
| F22 | The kill switch is the key `DisablePrivateInterfaces` in the app's defaults domain; **only an absent key or an explicit false leaves the interfaces on**, so `-bool true` turns them off. Its reason reads "the developer default DisablePrivateInterfaces is on" | `Sources/VMRunner/Model/PrivateCapabilityPolicy.swift:24-32,61-67` |
| F23 | The developer default is the key `WindowsStartsWithoutPMU`, read once at each start; **only an explicit Bool true counts** | `Sources/VMRunner/Engine/WindowsStartSettings.swift:9-15` |
| F24 | If the policy denies the capability, the capability is **not asked** and the start fails with `SetupError.requiredCapabilityUnavailable(guest: .windows, capability: "performance-monitoring emulation", reason: ...)`, unless `WindowsStartsWithoutPMU` is on: then one `notice` is logged in the category `machine` (`Windows starts without the performance-monitoring emulation (<reason>): WindowsStartsWithoutPMU is on`, its three interpolated parts public) and the start goes on. If the policy allows it, the capability is applied and read back; unavailable gives the same error (reason from the capability module); nothing is logged on success | `Sources/VMRunner/Engine/ConfigurationBuilder+Windows.swift:29-47`, `Sources/VMRunner/Engine/WindowsStartSettings.swift:30-34` |
| F25 | **The expected start error text of sub-run B, first start**: `Windows needs the performance-monitoring emulation, which is unavailable: the developer default DisablePrivateInterfaces is on.` (an expectation derived from the code, to be compared with what the app says) | `Sources/VMRunner/Engine/SetupError.swift:29,69-70`, `Sources/PrivateInterfaces/PrivateCapability.swift:6-10`, F22 |
| F26 | The capability module checks, in order: its own kill switch, **the host build `kern.osversion` against `26A0` to `26Z99999`**, then the class `VZGenericPlatformConfiguration`, the setter `_setPerformanceMonitoringUnitEmulationEnabled:` (type `v@:B`) and the getter `_performanceMonitoringUnitEmulationEnabled` (`B@:`); then the value is set and read back. A build outside the range gives `macOS build <b> is outside the builds it was verified on (26A0 to 26Z99999)` | `Sources/PrivateInterfaces/PMUEmulation.swift:11-16`, `Sources/PrivateInterfaces/CapabilityRegistry.swift:79-99`, `Sources/PrivateInterfaces/CapabilityApply.swift:10-31`, `Sources/PrivateInterfaces/OSBuild.swift:39-45` |
| F27 | A failed start is logged as `Start failed (<domain code>): <description>` with the **description private** (redacted in the log), is kept as the controller's message, shown in an alert in the machine's window, and returned by the control service (`vmr control start` prints it and exits 1). So the **verbatim error text comes from `vmr control start`'s output and the window's alert (Accessibility), not from the log** | `Sources/VMRunner/Engine/VMController.swift:233-237`, `Sources/VMRunner/Views/Machine/MachineView.swift:15-22`, `Sources/VMRunner/Model/VMLibrary+Commands.swift:26-27,65-69`, `Sources/VMRunner/Model/LibraryControlMachines.swift:52-57`, `Sources/DevTools/Control/ControlInvocation.swift:25-28` |
| F28 | `vmr control` (calls `list`, `state`, `log`, `start`, `stop [--force]`, `screenshot`, `status`, `mcp`; this run uses only `list`, `state`, `start` and `stop`) needs: the service turned on by the default `runsControlService` (read at launch), a token file (mode 0600) holding a secret whose SHA-256 digest is in `<data>/Control/tokens.json`, the machine's `agentAccess` true; the socket is `<data>/Control/control.sock`. A start the app would ask about is refused; the service answers a start within 120 s | `Sources/VMRunner/Engine/ControlService.swift:34-36,42,70`, `Sources/VMRunner/Model/PreferencesDomain.swift:43`, `Sources/ControlProtocol/ControlToken.swift:5-6,20-28`, `Sources/VMRunner/Model/LibraryControlMachines.swift:43,49`, `Sources/DevTools/CLI/ControlCommand.swift:10-24,154-169` |
| F29 | The bundle identifier of the built app is `com.example.VMRunner`; the app logs under it (subsystem), categories `storage`, `network`, `machine`, `input`, `display`, `control`, `container`; with `VMRUNNER_DATA_DIR` set its settings live in the defaults domain `<identifier>.data-directory-override` | `Resources/Info.plist:5`, `Sources/VMRunner/Model/Log.swift:11-18`, `Sources/VMRunner/Model/PreferencesDomain.swift:6,11` |
| F30 | The machine's runtime limit (`maxRuntimeMinutes`) asks the guest to shut down when it is reached, then forces the stop 30 s later | `Sources/VMRunner/Engine/VMController.swift:240-248`, `Sources/VMRunner/Model/RuntimeLimit.swift:9` |
| F31 | The app logs, always (a notice, kept), `Starting display W×H px ... source fixed size ...` at each cold start | `Sources/VMRunner/Engine/StartDisplayLog.swift:6-18` |
| F32 | `swift run vmr build-app` builds the app's product (release by default), assembles `build/VMRunner.app` under the package root, ad-hoc signs it with the hardened runtime and `Resources/VMRunner.entitlements` (virtualization and audio input), and verifies the result; `swift run vmr` itself leaves the `vmr` tool in `.build/debug/vmr` | `Sources/DevTools/CLI/BuildAppCommand.swift:8-60`, `Resources/VMRunner.entitlements` |
| F33 | CONTRIBUTING's real-guest conditions (scratch directory, caps of 2 CPUs and 2048 MiB with a stated exception for a macOS guest, hard run-time limit, no screen and no keys, only processes you started are signalled, everything removed) and `VMRUNNER_DATA_DIR` | `CONTRIBUTING.md:203-240` |

### Not established from the code (marked here and in the report as such)

- **N1. Which process hosts the guest.** The framework runs a guest in its own helper process, `com.apple.Virtualization.VirtualMachine`, parented to launchd and not to the app
  (seen in the container run of 2026-10-25; framework internals, not this repository). The run finds it as the process that is new when the machine starts; if none appears within 20 s the
  guest is hosted by the app process and the report says so. Both processes are sampled either way.
- **N2. Whether this Mac's `kern.osversion` is inside `26A0`...`26Z99999`** (F26). Step P2 prints it (on the Mac this card was written on it read `26A434`, macOS 27.0.1, inside the range). Outside the range, sub-run A can only produce the capability error (a result), and B's second start is the
  only boot.
- **N3. What the firmware does with the installer on the USB drive** (whether it boots it, how long the "Press any key" prompt stays, what a hang or a black window means). Only the owner's looks and the samples answer.
- **N4. Whether a permission prompt for the Downloads folder appears** when the app opens the ISO there. The agent never answers a prompt; the owner may. A read refused by the system is a stop condition (record the words).
- **N5. The exact formatting of `vmr control`'s failure line** (it is `<message> (<code>)` per `ControlInvocation.swift:28`, exit 1 per its help); recorded verbatim.
- **N6. Whether Accessibility is available** to the program that runs the agent's commands (step 4 prints it); if not, the owner reads the window and the error text comes from `vmr control` alone.
- **N7. Whether the New Machine sheet offers Windows after the merge** (cards of the chain after the fifth). It does not matter here: the hand-made path (F3, F4) works either way, and the report records which it was.
- **N8. How `ps %cpu` is defined on this Mac** (a decaying average). The CSV therefore also carries the cumulative CPU time, from which the digest computes the use over each 10-second interval; the digest's figures are those.

## Files and processes the run creates

All paths below come from `/tmp/vmr-windows-run.env`, written by step 1 (`TS` is `date +%m%d%H%M%S`, ten digits, so that the control socket path stays far under 103 bytes):

| Variable | Path | Holds |
|---|---|---|
| env file | `/tmp/vmr-windows-run.env` | the variables below |
| `DATA` | `/tmp/vmr-windows-run-$TS` | `VMRUNNER_DATA_DIR`: the app's data folder, new, mode 0700: `Machines/` (two bundles), `Control/` (token digest, socket), `Machines.approvals.json` (made by the app) |
| `TOOLS` | `/tmp/vmr-windows-run-$TS-tools` | the scripts and the one small program this card gives (your own files, not downloaded) |
| `NOTES` | `/tmp/vmr-windows-run-$TS-notes` | `token.txt` (0600), `pids.txt`, `ids.txt`, the ISO's before/after stat, per-run folders `A/`, `B1/`, `B2/` |
| `SRC` | `/tmp/vmr-windows-run-$TS-src` | the detached worktree; the app is `$SRC/build/VMRunner.app` (`APP`), the tool `$SRC/.build/debug/vmr` (`V`) |
| defaults | `~/Library/Preferences/com.example.VMRunner.data-directory-override.plist` | the run's settings: `runsControlService`, and for B `DisablePrivateInterfaces` and `WindowsStartsWithoutPMU` |
| the ISO | `~/Downloads/Windows11_Client_arm64_en-us_26300_9457.iso` | **not ours; read-only; referenced in place; never in the list of things removed** |

Processes: the scratch app (one per run), a `log stream`, a sampler, a watchdog, and the framework's guest helper (read, never started by us). Every pid goes into `$NOTES/pids.txt` and the run's `pids.txt`.

## Steps

### Preconditions (STOP and report if any fails)

P1. Authorisation (above). P2. Record `sw_vers`, `uname -m`, `sysctl -n hw.model`, `sysctl -n kern.osversion` and whether the build is in range:
`/bin/bash --noprofile --norc -c 'sw_vers; uname -m; sysctl -n hw.model; b=$(sysctl -n kern.osversion); echo "kern.osversion=$b"; if printf "%s" "$b" | grep -E -q "^26[A-Z][0-9]+[a-z]?$"; then echo "IN RANGE of 26A0..26Z99999"; else echo "OUTSIDE RANGE (N2): sub-run A will end in the capability error"; fi'`
(outside the range is not a stop: it is a result, and decides the plan of A). P3. `df -g /tmp` shows at least **50 GiB** free in the "Avail" column (the build adds to `/tmp`; the run needs 40 GiB after it).
P4. **No other VMRunner is running**: `pgrep -x VMRunner` prints nothing (do not signal one that does). P5. **Nothing of an earlier run is left**: `ls -d /tmp/vmr-windows-run*` says "No such file" (a leftover is
reported, never reused or deleted). P6. `defaults read com.example.VMRunner.data-directory-override` answers `does not exist` (the run owns that domain; if it exists, STOP and report).
P7. No organisation policy touches the two features the run uses: `defaults read com.example.VMRunner AllowPrivateInterfaces` and `defaults read com.example.VMRunner AllowControlService` each answer `does not exist` or `1`,
and `ls "/Library/Managed Preferences" | grep -i vmrunner` prints nothing. P8. The chain is in the code that will be built:
`git -C ~/Developer/g-cqd/VMRunner log main --oneline | grep -F "Build a Windows machine: generic platform with EFI"` prints one line. Not merged: STOP (the owner may name another place to build from in this conversation; record it).
P9. Record the baselines the end compares (reads only):
`/bin/bash --noprofile --norc -c 'stat -f "%z %m" "$HOME/Library/Preferences/com.example.VMRunner.plist" 2>&1; ls -t "$HOME/Library/Logs/DiagnosticReports" | head -5; ps -ax -o pid=,command= | grep -F Virtualization.VirtualMachine | grep -v grep'`
(the first line is the size and mtime of the owner's own preferences, which must be the same at the end; the second block the newest crash-report names; the third the framework guest processes already on this Mac, none of them ours).

### 1. The run's variables and folders (the fresh-path check)

```
/bin/bash --noprofile --norc -c 'set -eu; if ls -d /tmp/vmr-windows-run* > /dev/null 2>&1; then echo "STOP: a leftover exists"; ls -d /tmp/vmr-windows-run*; exit 1; fi; TS=$(date +%m%d%H%M%S); P=/tmp/vmr-windows-run-$TS; { echo "TS=$TS"; echo "DATA=$P"; echo "TOOLS=$P-tools"; echo "NOTES=$P-notes"; echo "SRC=$P-src"; echo "APP=$P-src/build/VMRunner.app"; echo "V=$P-src/.build/debug/vmr"; echo "SOCK=$P/Control/control.sock"; echo "TOKEN=$P-notes/token.txt"; echo "REPO=~/Developer/g-cqd/VMRunner"; echo "ISO=~/Downloads/Windows11_Client_arm64_en-us_26300_9457.iso"; echo "ISO_SHA256=8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c"; } > /tmp/vmr-windows-run.env; for d in "$P" "$P-tools" "$P-notes"; do mkdir -m 700 "$d"; done; mkdir -m 700 "$P/Machines" "$P/Control"; cat /tmp/vmr-windows-run.env; ls -ld /tmp/vmr-windows-run-*'
```

Expected: twelve variable lines, then the three top folders (`DATA`, `-tools`, `-notes`), each `drwx------` (`Machines` and `Control` are made inside `DATA`, also `drwx------`). From here every command starts with `. /tmp/vmr-windows-run.env;` inside `bash -c`.
**The card's clock does not start here**: the 50-minute whole-card cap starts at the first launch of the app (step "Sub-run A", X3), because the build, the hashing and the file preparation start no guest; `budget.sh` (below) keeps it.

### 2. Build the app (the only build of this card)

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; git -C "$REPO" worktree add --detach "$SRC" main && git -C "$SRC" log --oneline -8 && git -C "$SRC" rev-parse HEAD'
```

The log shows the chain's commits, "Build a Windows machine: generic platform with EFI, ..." among them. Then, in the background (minutes):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; cd "$SRC" && swift run vmr build-app > "$NOTES/build.log" 2>&1; echo exit=$?'
```

Expected `exit=0`, `$APP` exists, `$V` is executable, and:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; ls -ld "$APP" "$V"; codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|flags|Signature"; codesign -d --entitlements - "$APP" 2>&1 | grep -E "com.apple"; BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"); echo "BUNDLE_ID=$BUNDLE_ID" >> /tmp/vmr-windows-run.env; echo "DOMAIN=$BUNDLE_ID.data-directory-override" >> /tmp/vmr-windows-run.env; grep -F -e BUNDLE_ID -e DOMAIN /tmp/vmr-windows-run.env; tail -3 "$NOTES/build.log"'
```

Expected: `flags=0x10002(adhoc,runtime)`, the entitlements `com.apple.security.virtualization` and `com.apple.security.device.audio-input` and nothing else, the identifier `com.example.VMRunner`. If the identifier differs, use the printed one
everywhere (the later commands read `$BUNDLE_ID` and `$DOMAIN`; P6 and P7 then used the wrong domain: redo them with the printed one). **Fact check** (the strings this card relies on are in the built tree; each count must be 1 or more):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; cd "$SRC"; for pair in "Sources/VMRunner/Engine/WindowsStartSettings.swift:WindowsStartsWithoutPMU" "Sources/VMRunner/Model/PrivateCapabilityPolicy.swift:DisablePrivateInterfaces" "Sources/VMRunner/Engine/SetupError.swift:which is unavailable" "Sources/VMRunner/Engine/ConfigurationBuilder+Windows.swift:Windows starts without" "Sources/VMRunner/Model/PreferencesDomain.swift:runsControlService" "Sources/VMRunner/Model/VMLibrary.swift:approvals.json" "Sources/VMRunner/Model/VMConfig.swift:case macOS, linux, windows" "Sources/VMRunner/Model/Storage.swift:static let installerName"; do f=${pair%%:*}; s=${pair#*:}; printf "%s  %s: " "$(grep -c -F -- "$s" "$f")" "$s"; echo "$f"; done; grep -n -F "newMachineChoices" Sources/VMRunner/Model/VMConfig.swift | head -2'
```

A count of 0, or a `newMachineChoices` list that now holds `.windows` (N7: record it; the hand-made path is still used), is recorded. A 0 for a string of F22 to F25 is a STOP: the code changed under this card.

### 3. The media (read-only)

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; set -u; [ -f "$ISO" ] && [ -r "$ISO" ] || { echo "STOP: the ISO is missing or unreadable"; exit 1; }; { ls -l "$ISO"; stat -f "%z %m %Sp" "$ISO"; } | tee "$NOTES/iso-before.txt"; have=$(shasum -a 256 "$ISO" | awk "{ print \$1 }"); echo "sha256=$have"; if [ "$have" = "$ISO_SHA256" ]; then echo "SHA-256 OK"; else echo "SHA-256 MISMATCH: STOP"; fi'
```

Expected: the size and mode, `SHA-256 OK` (Insider build 26300.9457). **Mismatch, or "Operation not permitted" (N4: the system refuses this program the Downloads folder; the agent changes no permission), is a STOP.** Nothing else touches the file.

### 4. Tools

Write these files into `$TOOLS` (paths printed by step 1), exactly, then `chmod 700 "$TOOLS"/*.sh`.

`$TOOLS/mkefi.swift` (the two calls of `Provisioner.swift:51-52`; it starts no virtual machine and needs no entitlement):

```swift
// usage: mkefi EFIVariables.fd MachineIdentifier
// Makes the two files the app's setup makes for a Linux ISO or Windows machine: an empty EFI variable store and a generic machine identifier.
import Foundation
import Virtualization

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: mkefi EFIVariables.fd MachineIdentifier\n".utf8))
    exit(64)
}
_ = try VZEFIVariableStore(creatingVariableStoreAt: URL(filePath: arguments[1]), options: [.allowOverwrite])
try VZGenericMachineIdentifier().dataRepresentation.write(to: URL(filePath: arguments[2]))
```

`$TOOLS/ax.swift`: the Accessibility helper, **verbatim from `cards2/T-RUN.md`**: the block under the heading "### 5. Tools" whose first line is `$TOOLS/ax.swift` (locate it by that text; it is about 125 lines
and refuses any pid whose executable is not `$VMR_APP/Contents/MacOS/VMRunner`, before it asks anything of it). Only its `trusted`, `windows` and `text` commands are used here; the run presses nothing.

`$TOOLS/mkbundle.sh`:

```bash
#!/bin/bash
# usage: mkbundle.sh NAME    DATA, TOOLS and NOTES come from the run's env file.
# Makes the folder of one Windows machine the way the app's setup does for an installer machine (Provisioner.provisionInstallerMachine):
# the private folder, a sparse 64 GiB Disk.img, an EFI variable store and a machine identifier.
# It does NOT write config.json: the agent writes it with the Write tool, exactly as the card gives it.
set -euo pipefail
. /tmp/vmr-windows-run.env
umask 077
name=$1
id=$(uuidgen)
bundle="$DATA/Machines/$id.vm"
mkdir -m 700 "$bundle"
perl -e 'open(my $f, ">", $ARGV[0]) or die "open: $!"; truncate($f, 64 << 30) or die "truncate: $!"; close($f)' "$bundle/Disk.img"
"$TOOLS/mkefi" "$bundle/EFIVariables.fd" "$bundle/MachineIdentifier"
chmod 600 "$bundle/Disk.img" "$bundle/EFIVariables.fd" "$bundle/MachineIdentifier"
echo "$name $id" | tee -a "$NOTES/ids.txt"
echo "  Disk.img apparent $(stat -f %z "$bundle/Disk.img") bytes, allocated $(du -k "$bundle/Disk.img" | awk '{ print $1 }') KiB"
```

`$TOOLS/mktoken.sh` (the control service's token: only its digest is stored; the secret goes to `$TOKEN` and is never printed, put in an argument or in the report):

```bash
#!/bin/bash
set -euo pipefail
. /tmp/vmr-windows-run.env
umask 077
SECRET="vmrc_$(openssl rand -hex 32)"
printf '%s' "$SECRET" > "$TOKEN"
DIGEST=$(printf '%s' "$SECRET" | shasum -a 256 | cut -d' ' -f1)
CREATED=$(( $(date +%s) - 978307200 ))
printf '[{"id": "%s", "name": "w-run", "capabilities": ["list", "start", "state", "stop"], "created": %s, "digest": "%s"}]\n' "$(uuidgen)" "$CREATED" "$DIGEST" > "$DATA/Control/tokens.json"
chmod 600 "$TOKEN" "$DATA/Control/tokens.json"
ls -l "$TOKEN" "$DATA/Control/tokens.json"
```

`$TOOLS/budget.sh` (the whole-card clock: it starts at the first call, made by `launch.sh`):

```bash
#!/bin/bash
# usage: budget.sh [start]   Without an argument: prints the minutes left of the 50 of the card and OK or STOP (STOP under 17: a sub-run needs about 16).
. /tmp/vmr-windows-run.env
f="$NOTES/card.start"
if [ "${1:-}" = "start" ]; then [ -e "$f" ] || date +%s > "$f"; fi
[ -e "$f" ] || { echo "the card's clock has not started: 50 minutes left, OK"; exit 0; }
left=$(( 50 - ($(date +%s) - $(cat "$f")) / 60 ))
if [ "$left" -ge 17 ]; then echo "$left minutes left of 50: OK"; else echo "$left minutes left of 50: STOP (do not launch another sub-run)"; fi
```

`$TOOLS/sample.sh` (read only: every 10 s one CSV row of the app and of the guest's helper; every 30 s a row of the disk's allocated size, the firmware store's size and mtime, the machine's state and the free space):

```bash
#!/bin/bash
# usage: sample.sh RUN APP_PID DISK EFI MAX_SECONDS MACHINE_ID
# Writes RUN/cpu.csv (10 s), RUN/disk.csv and RUN/state.csv (30 s). The helper's pid is read each tick from RUN/helper.pid; T0 from RUN/T0.epoch.
# Ends at MAX_SECONDS or when RUN/sampler.stop exists. It starts nothing and signals nothing.
. /tmp/vmr-windows-run.env
dir="$NOTES/$1"; app=$2; disk=$3; efi=$4; mid=$6
end=$(( $(date +%s) + $5 ))
echo "epoch,tplus_s,app_pid,app_cpu_pct,app_cputime,app_rss_kib,helper_pid,helper_cpu_pct,helper_cputime,helper_rss_kib" > "$dir/cpu.csv"
echo "epoch,tplus_s,disk_alloc_kib,disk_apparent_bytes,disk_mtime,efi_bytes,efi_mtime,free_kib" > "$dir/disk.csv"
echo "epoch,tplus_s,state" > "$dir/state.csv"
row() { ps -o %cpu=,time=,rss= -p "$1" 2> /dev/null | awk '{ print $1 "," $2 "," $3 }'; }
n=0
while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$dir/sampler.stop" ]; do
  now=$(date +%s)
  t=""
  [ -s "$dir/T0.epoch" ] && t=$(( now - $(cat "$dir/T0.epoch") ))
  a=$(row "$app"); [ -n "$a" ] || a=",,"
  h=$(cat "$dir/helper.pid" 2> /dev/null || true)
  hv=",,"
  if [ -n "$h" ]; then hv=$(row "$h"); [ -n "$hv" ] || hv=",,"; fi
  echo "$now,$t,$app,$a,$h,$hv" >> "$dir/cpu.csv"
  if [ $(( n % 3 )) -eq 0 ]; then
    alloc=$(du -k "$disk" 2> /dev/null | awk '{ print $1 }')
    d=$(stat -f '%z,%m' "$disk" 2> /dev/null || echo ",")
    e=$(stat -f '%z,%m' "$efi" 2> /dev/null || echo ",")
    free=$(df -k /tmp | awk 'NR == 2 { print $4 }')
    echo "$now,$t,$alloc,$d,$e,$free" >> "$dir/disk.csv"
    s=$("$V" control state "$mid" --socket "$SOCK" --token-file "$TOKEN" 2>&1 | tr '\n,' ' ;')
    echo "$now,$t,$s" >> "$dir/state.csv"
  fi
  n=$(( n + 1 ))
  sleep 10
done
```

`$TOOLS/watchdog.sh` (the card's own time limits and a free-space guard, enforced by itself, so that they hold even while the agent waits for the owner):

```bash
#!/bin/bash
# usage: watchdog.sh RUN
# - at T0 + 720 s (planned end of a booted run): force stop through the control service;
# - at launch + 900 s (the 15-minute cap of a sub-run): force stop; at launch + 930 s: kill -TERM the app (recorded pid), kill -KILL 10 s later;
# - whenever /tmp has under 8 GiB free: force stop.
# After the app is gone, a guest helper of the run that is still there 15 s later gets a kill -TERM (its recorded pid, only while it is a framework guest process).
. /tmp/vmr-windows-run.env
dir="$NOTES/$1"; app=$(cat "$dir/app.pid"); launch=$(cat "$dir/launch.epoch"); mid=$(cat "$dir/machine.id")
say() { echo "$(date '+%H:%M:%S') $*" >> "$dir/watchdog.log"; }
stop_machine() { "$V" control stop "$mid" --force --socket "$SOCK" --token-file "$TOKEN" >> "$dir/watchdog.log" 2>&1; }
planned=0; capped=0; low=0; i=0
while kill -0 "$app" 2> /dev/null && [ ! -e "$dir/watchdog.stop" ]; do
  now=$(date +%s)
  if [ "$planned" -eq 0 ] && [ -s "$dir/T0.epoch" ] && [ "$now" -ge $(( $(cat "$dir/T0.epoch") + 720 )) ]; then
    planned=1; say "planned end, T0 + 720 s: force stop"; stop_machine
  fi
  if [ "$capped" -eq 0 ] && [ "$now" -ge $(( launch + 900 )) ]; then
    capped=1; say "cap of 15 minutes after the launch: force stop"; stop_machine
  fi
  if [ "$now" -ge $(( launch + 930 )) ]; then
    say "cap + 30 s: kill -TERM $app"; kill -TERM "$app"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$app" 2> /dev/null || break; sleep 0.5; done
    kill -0 "$app" 2> /dev/null && { say "kill -KILL $app"; kill -KILL "$app"; }
    break
  fi
  if [ $(( i % 6 )) -eq 0 ] && [ "$low" -eq 0 ]; then
    free=$(df -k /tmp | awk 'NR == 2 { print $4 }')
    if [ "$free" -lt 8388608 ]; then low=1; say "under 8 GiB free ($free KiB): force stop"; stop_machine; fi
  fi
  i=$(( i + 1 ))
  sleep 5
done
h=$(cat "$dir/helper.pid" 2> /dev/null || true)
if [ -n "$h" ] && ! kill -0 "$app" 2> /dev/null && [ ! -e "$dir/watchdog.stop" ]; then
  for _ in $(seq 1 30); do kill -0 "$h" 2> /dev/null || break; sleep 0.5; done
  if kill -0 "$h" 2> /dev/null && ps -o command= -p "$h" | grep -q -F Virtualization.VirtualMachine; then say "helper $h still there after the app: kill -TERM"; kill -TERM "$h"; fi
fi
say "watchdog ends"
```

`$TOOLS/launch.sh` (the log stream, the scratch app, the sampler and the watchdog; every pid goes into `$NOTES/pids.txt` and the run's own `pids.txt`):

```bash
#!/bin/bash
# usage: launch.sh RUN NAME    RUN is a label (A, B1, B2) and NAME the machine's name (win-a, win-b).
set -uo pipefail
. /tmp/vmr-windows-run.env
run=$1
name=$2
dir="$NOTES/$run"
mkdir -m 700 "$dir"
mid=$(awk -v n="$name" '$1 == n { print $2 }' "$NOTES/ids.txt")
[ -n "$mid" ] || { echo "no machine named $name"; exit 1; }
bundle="$DATA/Machines/$mid.vm"
echo "$mid" > "$dir/machine.id"
record() { echo "$1 $2" >> "$NOTES/pids.txt"; echo "$1 $2" >> "$dir/pids.txt"; }
{ ps -ax -o pid=,command= | grep -F 'Virtualization.VirtualMachine' | grep -v grep | awk '{ print $1 }'; } > "$dir/helpers-before.txt" || true
bash "$TOOLS/budget.sh" start
cd /
VMRUNNER_DATA_DIR="$DATA" "$APP/Contents/MacOS/VMRunner" > "$dir/app.log" 2>&1 &
app=$!
record app "$app"
echo "$app" > "$dir/app.pid"
date +%s > "$dir/launch.epoch"
: > "$dir/helper.pid"
/usr/bin/log stream --level info --style compact --predicate "subsystem == \"$BUNDLE_ID\" AND processID == $app" > "$dir/logstream.txt" 2>&1 &
record logstream "$!"
bash "$TOOLS/sample.sh" "$run" "$app" "$bundle/Disk.img" "$bundle/EFIVariables.fd" 1100 "$mid" > /dev/null 2>&1 &
record sampler "$!"
bash "$TOOLS/watchdog.sh" "$run" > /dev/null 2>&1 &
record watchdog "$!"
for _ in $(seq 1 120); do
  [ -S "$SOCK" ] && break
  kill -0 "$app" 2> /dev/null || { echo "the app exited within the first minute; read $dir/app.log"; exit 2; }
  sleep 0.5
done
[ -S "$SOCK" ] || { echo "no control socket after 60 s"; exit 3; }
echo "run=$run machine=$name id=$mid app=$app socket=ready launch=$(cat "$dir/launch.epoch")"
```

`$TOOLS/start.sh` (starts the run's machine through the control service, records T0 and finds the guest's process):

```bash
#!/bin/bash
# usage: start.sh RUN    T0 is the moment the answer "running" came back. Exit status = the status of `vmr control start`.
. /tmp/vmr-windows-run.env
run=$1
dir="$NOTES/$run"
mid=$(cat "$dir/machine.id")
requested=$(date +%s)
"$V" control start "$mid" --socket "$SOCK" --token-file "$TOKEN" > "$dir/start.out" 2>&1
status=$?
answered=$(date +%s)
echo "$status" > "$dir/start.status"
echo "requested=$requested answered=$answered exit=$status ($(date -r "$answered" '+%H:%M:%S'))" | tee "$dir/start.times"
echo "--- vmr control start printed:"
cat "$dir/start.out"
[ "$status" -eq 0 ] || exit "$status"
echo "$answered" > "$dir/T0.epoch"
helper=""
for _ in $(seq 1 40); do
  helper=$(ps -ax -o pid=,command= | grep -F 'Virtualization.VirtualMachine' | grep -v grep | awk '{ print $1 }' | grep -v -x -F -f "$dir/helpers-before.txt" | head -n 1 || true)
  [ -n "$helper" ] && break
  sleep 0.5
done
if [ -n "$helper" ]; then
  echo "$helper" > "$dir/helper.pid"
  echo "helper $helper" >> "$NOTES/pids.txt"; echo "helper $helper" >> "$dir/pids.txt"
  echo "guest process: helper pid $helper ($(ps -o command= -p "$helper" | cut -c1-120))"
else
  echo "guest process: no new Virtualization.VirtualMachine process within 20 s: the app process hosts the guest (N1)"
fi
```

`$TOOLS/schedule.sh` (prints the clock times the owner follows):

```bash
#!/bin/bash
# usage: schedule.sh RUN
. /tmp/vmr-windows-run.env
dir="$NOTES/$1"
t0=$(cat "$dir/T0.epoch")
launch=$(cat "$dir/launch.epoch")
at() { date -r $(( t0 + $1 )) '+%H:%M:%S'; }
echo "T0 (the machine runs)        $(date -r "$t0" '+%H:%M:%S')"
echo "look 1: 2:00 to 3:00 after T0  $(at 120) to $(at 180)"
echo "look 2: 8:00 to 9:00 after T0  $(at 480) to $(at 540)"
echo "planned stop (watchdog)        $(at 720)  (T0 + 12:00)"
echo "hard cap, 15 minutes after launch  $(date -r $(( launch + 900 )) '+%H:%M:%S') (force stop), $(date -r $(( launch + 930 )) '+%H:%M:%S') (kill)"
```

`$TOOLS/waitto.sh` (waits for a time after T0 without a fixed sleep; at most 540 s per call):

```bash
#!/bin/bash
# usage: waitto.sh RUN SECONDS   exit 0: T0 + SECONDS reached; 124: not yet, call again; 2: the app is gone.
. /tmp/vmr-windows-run.env
dir="$NOTES/$1"
app=$(cat "$dir/app.pid")
target=$(( $(cat "$dir/T0.epoch") + $2 ))
limit=$(( $(date +%s) + 540 ))
until [ "$(date +%s)" -ge "$target" ]; do
  kill -0 "$app" 2> /dev/null || { echo "the app is gone before T0 + $2 s"; exit 2; }
  [ "$(date +%s)" -ge "$limit" ] && { echo "not yet at $(date '+%H:%M:%S'): call again"; exit 124; }
  sleep 2
done
echo "reached T0 + $2 s at $(date '+%H:%M:%S')"
```

`$TOOLS/collect.sh` (one read-only observation, appended to the run's `observations.txt`):

```bash
#!/bin/bash
# usage: collect.sh RUN LABEL
. /tmp/vmr-windows-run.env
run=$1
label=$2
dir="$NOTES/$run"
app=$(cat "$dir/app.pid")
mid=$(cat "$dir/machine.id")
t="-"
[ -s "$dir/T0.epoch" ] && t=$(( $(date +%s) - $(cat "$dir/T0.epoch") ))
{
  echo "== $label $(date '+%H:%M:%S') T+${t}s app $app alive: $(kill -0 "$app" 2> /dev/null && echo yes || echo NO)"
  "$V" control state "$mid" --socket "$SOCK" --token-file "$TOKEN" 2>&1
  if [ -x "$TOOLS/ax" ]; then VMR_APP="$APP" "$TOOLS/ax" windows "$app" 2>&1; VMR_APP="$APP" "$TOOLS/ax" text "$app" 2>&1; fi
  ps -o pid=,time=,%cpu=,rss= -p "$app$( [ -s "$dir/helper.pid" ] && echo ",$(cat "$dir/helper.pid")" )" 2>&1
} | tee -a "$dir/observations.txt"
```

`$TOOLS/quit.sh` (ends a run's processes, by recorded pids only):

```bash
#!/bin/bash
# usage: quit.sh RUN    Stops the sampler and the watchdog by their files, the log stream and the app by their recorded pids (TERM, then KILL after 10 s).
. /tmp/vmr-windows-run.env
dir="$NOTES/$1"
touch "$dir/sampler.stop" "$dir/watchdog.stop"
gone() { for _ in $(seq 1 $(( $2 * 2 ))); do kill -0 "$1" 2> /dev/null || return 0; sleep 0.5; done; return 1; }
while read -r kind pid; do
  case "$kind" in
    sampler | watchdog) gone "$pid" 15 || { echo "$kind $pid still running: kill -TERM"; kill -TERM "$pid"; } ;;
    logstream) kill -TERM "$pid" 2> /dev/null; gone "$pid" 5 ;;
  esac
done < "$dir/pids.txt"
app=$(cat "$dir/app.pid")
if kill -0 "$app" 2> /dev/null; then
  kill -TERM "$app"
  gone "$app" 10 || { echo "app $app: kill -KILL"; kill -KILL "$app"; }
fi
h=$(cat "$dir/helper.pid" 2> /dev/null || true)
if [ -n "$h" ] && kill -0 "$h" 2> /dev/null; then
  gone "$h" 15 || { ps -o command= -p "$h" | grep -q -F Virtualization.VirtualMachine && { echo "helper $h still there 15 s after the app: kill -TERM"; kill -TERM "$h"; }; }
fi
echo "app gone: $(kill -0 "$app" 2> /dev/null && echo NO || echo yes)"
echo "VMRunner processes: $(pgrep -x VMRunner | tr '\n' ' ')"
echo "framework guest processes now:"; ps -ax -o pid=,command= | grep -F Virtualization.VirtualMachine | grep -v grep || echo "  none"
```

`$TOOLS/digest.sh` (the tables of the report, from the run's raw files):

```bash
#!/bin/bash
# usage: digest.sh RUN    After the run: CPU per interval and per minute, the longest busy streak, the disk's allocated size per minute, the log lines.
. /tmp/vmr-windows-run.env
run=$1
dir="$NOTES/$run"
app=$(cat "$dir/app.pid")
awk -F, '
function secs(t,   n, p) { n = split(t, p, ":"); return n == 3 ? p[1] * 3600 + p[2] * 60 + p[3] : p[1] * 60 + p[2] }
NR == 1 { print "epoch,tplus_s,app_interval_cpu_pct,app_rss_kib,helper_interval_cpu_pct,helper_rss_kib"; next }
{
  ai = ""; hi = ""
  if ($5 != "") { s = secs($5); if (pe != "" && pa != "" && $1 > pe) ai = sprintf("%.0f", 100 * (s - pa) / ($1 - pe)); pa = s } else { pa = "" }
  if ($9 != "") { s = secs($9); if (pe != "" && ph != "" && $1 > pe) hi = sprintf("%.0f", 100 * (s - ph) / ($1 - pe)); ph = s } else { ph = "" }
  pe = $1
  print $1 "," $2 "," ai "," $6 "," hi "," $10
}' "$dir/cpu.csv" > "$dir/intervals.csv"
echo "--- processes sampled (pids): app $app, helper $(cat "$dir/helper.pid" 2> /dev/null)"
echo "--- CPU per minute after T0 (interval use from the cumulative CPU time; 100% = one core; the guest has 4 CPUs)"
awk -F, '
BEGIN { last = -1 }
NR == 1 { next }
$2 != "" && $2 + 0 >= 0 {
  m = int($2 / 60); if (m > last) last = m
  if ($5 != "") { hs[m] += $5; hn[m]++; if ($5 + 0 > hm[m] + 0) hm[m] = $5 }
  if ($3 != "") { as[m] += $3; an[m]++; if ($3 + 0 > am[m] + 0) am[m] = $3 }
  if ($5 != "" && $5 + 0 >= 300) { hst++; if (hst > hbest) { hbest = hst; hend = $2 } } else { hst = 0 }
  if ($3 != "" && $3 + 0 >= 300) { ast++; if (ast > abest) { abest = ast; aend = $2 } } else { ast = 0 }
}
END {
  for (m = 0; m <= last; m++)
    printf "T+%d min: helper mean %s%% max %s%% (%d samples); app mean %s%% max %s%% (%d samples)\n", m,
      (hn[m] ? sprintf("%.0f", hs[m] / hn[m]) : "-"), (hn[m] ? hm[m] : "-"), hn[m], (an[m] ? sprintf("%.0f", as[m] / an[m]) : "-"), (an[m] ? am[m] : "-"), an[m]
  printf "longest run of samples at or above 300%%: helper %d samples (%d s, ending %s); app %d samples (%d s, ending %s)\n", hbest, hbest * 10, (hbest ? "T+" hend " s" : "-"), abest, abest * 10, (abest ? "T+" aend " s" : "-")
}' "$dir/intervals.csv"
echo "--- peak resident set (KiB) of the app and of the helper"
awk -F, 'NR > 1 { if ($4 + 0 > a) a = $4 + 0; if ($6 + 0 > h) h = $6 + 0 } END { printf "app %d, helper %d\n", a, h }' "$dir/intervals.csv"
echo "--- Disk.img allocated size at the first sample of each minute after T0, and the firmware store"
awk -F, '
BEGIN { pm = -1 }
NR == 1 { next }
{
  if (first == "") first = $3 + 0
  if ($3 + 0 > max) max = $3 + 0
  last = $3 + 0
  if (!grew && $3 + 0 > first + 1024) { grew = 1; growt = ($2 == "" ? "before T0" : $2) }
  if (efi0 == "") efi0 = $7
  if ($7 != efi0 && !efichg) { efichg = 1; efit = ($2 == "" ? "before T0" : $2) }
  if ($2 != "" && $2 + 0 >= 0 && int($2 / 60) != pm) { pm = int($2 / 60); printf "T+%d min: Disk.img allocated %d KiB (%.1f MiB)\n", pm, $3, $3 / 1024 }
}
END { printf "first %d KiB, max %d KiB, last %d KiB; first growth beyond +1 MiB: %s; EFIVariables.fd mtime changed: %s (first: %s)\n", first, max, last, (grew ? "T+" growt " s" : "never"), (efichg ? "yes" : "no"), (efichg ? "T+" efit " s" : "-") }' "$dir/disk.csv"
echo "--- machine state samples (state.csv): distinct states in order"
awk -F, 'NR > 1 && $3 != prev { print $2 ": " $3; prev = $3 }' "$dir/state.csv"
echo "--- the app's own log (log show, the run's pid)"
start=$(date -r "$(cat "$dir/launch.epoch")" '+%Y-%m-%d %H:%M:%S')
/usr/bin/log show --start "$start" --info --style compact --predicate "subsystem == \"$BUNDLE_ID\" AND processID == $app" > "$dir/logshow.txt" 2>&1 || true
echo "lines: log show $(wc -l < "$dir/logshow.txt"), log stream $(wc -l < "$dir/logstream.txt")"
grep -E 'Starting display|Windows starts without|Start failed|error|fault|Couldn|refused' "$dir/logshow.txt" | head -40
echo "--- the app's log at error and fault level"
/usr/bin/log show --start "$start" --style compact --predicate "subsystem == \"$BUNDLE_ID\" AND processID == $app AND (messageType == error OR messageType == fault)" 2>&1 | head -20
echo "--- crash reports now (newest five), against the five of the baseline"
ls -t "$HOME/Library/Logs/DiagnosticReports" | head -5
echo "--- the machine's config.json keys the app rewrote (hasBooted, lastDisplayWidth, lastDisplayHeight)"
grep -E 'hasBooted|lastDisplay' "$DATA/Machines/$(cat "$dir/machine.id").vm/config.json" 2>&1
echo "--- watchdog"
cat "$dir/watchdog.log" 2>&1
```

Compile the one program and check the scripts (nothing starts; `mkefi` makes two files only when a script runs it):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; chmod 700 "$TOOLS"/*.sh; for f in "$TOOLS"/*.sh; do bash -n "$f" && echo "syntax ok: $f"; done; cd / && swiftc -O -o "$TOOLS/mkefi" "$TOOLS/mkefi.swift" && ls -l "$TOOLS/mkefi"; [ -f "$TOOLS/ax.swift" ] && swiftc -O -o "$TOOLS/ax" "$TOOLS/ax.swift" && VMR_APP="$APP" "$TOOLS/ax" windows $$; echo "ax refusal exit=$?"; [ -x "$TOOLS/ax" ] && "$TOOLS/ax" trusted'
```

Expected: `syntax ok` for each script, `mkefi` built, then `refused: pid ... runs ..., not .../VMRunner` and `exit=77` (the safety check refusing the shell's own pid: no Accessibility call was made), then `true` or `false`
(N6: `false` means the run continues without `ax`; `collect.sh` skips it if the binary is absent, and the owner reads the window).

### 5. The token, the defaults and the two machines

The token and the service setting (the app reads `runsControlService` at launch):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/mktoken.sh" && defaults delete "$DOMAIN" DisablePrivateInterfaces 2>&1; defaults delete "$DOMAIN" WindowsStartsWithoutPMU 2>&1; defaults write "$DOMAIN" runsControlService -bool true && defaults read "$DOMAIN"'
```

Expected: the two files `-rw-------`; the two `delete`s may answer that the pair does not exist (that is the default); the last `read` shows only `runsControlService = 1`.

The two machines (their folders, sparse disks, firmware stores and identifiers; **no `config.json` yet**):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; cd /; bash "$TOOLS/mkbundle.sh" win-a && bash "$TOOLS/mkbundle.sh" win-b; ls -l "$DATA/Machines"; ls -l "$DATA/Machines"/*.vm; ls "$DATA"; df -g /tmp | tail -1'
```

Expected: two lines `win-a <UUID>` and `win-b <UUID>`; each `Disk.img` apparent **68719476736 bytes** and allocated a few KiB at most (sparse: if it is gigabytes the file is not sparse: STOP); two `<UUID>.vm` folders (`drwx------`) each with `Disk.img`,
`EFIVariables.fd` (131072 bytes when the earlier run made one), `MachineIdentifier` (70 bytes), all `-rw-------`; **no `Machines.approvals.json`** in `$DATA` (the app makes it at its first load and approves both machines then; do not make
one); and at least **40 GiB** free (`Avail`; below that STOP). The disk's growth is bounded by what Setup writes in 12 minutes; the sampler and the watchdog's 8 GiB guard watch it.

**Write `config.json` of each machine with the Write tool** (never with a shell redirect), at `<DATA>/Machines/<UUID>.vm/config.json` (the literal paths printed above), replacing `<UUID>` by that machine's UUID, as
exactly this text (`name` is `win-a` or `win-b`; the rest is identical):

```json
{
  "id": "<UUID>",
  "name": "win-a",
  "guest": "windows",
  "isProvisioned": true,
  "cpuCount": 4,
  "memoryMiB": 8192,
  "diskGiB": 64,
  "diskInterface": "nvme",
  "networkMode": "nat",
  "displayWidth": 1920,
  "displayHeight": 1200,
  "fitsWindowAtStart": false,
  "automaticallyReconfiguresDisplay": false,
  "pointingDevice": "mouse",
  "audioOutput": false,
  "sharesClipboard": false,
  "maxRuntimeMinutes": 15,
  "installerISO": "~/Downloads/Windows11_Client_arm64_en-us_26300_9457.iso",
  "installerAttached": true,
  "agentAccess": true
}
```

Why each key (F8): the machine is a Windows one that needs no setup (`isProvisioned`, F9); 4 CPUs, 8192 MiB, a 64 GiB disk (the owner's figures; the disk number is only the config's note of the size, the file is the one made above); NVMe, NAT, a 1920 by 1200 framebuffer that does not follow the window
(`fitsWindowAtStart` and `automaticallyReconfiguresDisplay` false, F17: the owner asked for that size, and a fixed one makes the window comparable between runs); mouse pointer, no sound, no clipboard (the Windows defaults, F7, written out); the 15-minute runtime limit (F30);
the installer attached where it is (F18 to F20); `agentAccess` true, which is **not in the owner's list but is the switch that lets `vmr control` start and stop the machine** (F28). No `driverDiscPath` (F16), no `gpu`, no `secureBoot`, no console: a Windows machine refuses them (F6).

Check the files as the app will read them (`plutil` fails on JSON that does not parse; the folder name must equal the id; the last lines are the machine's keys as parsed):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; for d in "$DATA"/Machines/*.vm; do n=$(basename "$d" .vm); got=$(plutil -extract id raw -o - "$d/config.json") && { [ "$got" = "$n" ] && echo "id equals the folder name: $n" || echo "ID DIFFERS FROM THE FOLDER: $got $n"; }; plutil -p "$d/config.json"; done'
```

Expected for each machine: `id equals the folder name`, then the twenty keys exactly as written above (`"guest" => "windows"`, `"installerISO"` the owner's path). A parse error, a different id or a missing key: fix the file (it is the card's text), do not launch.

### 6. Baselines (read-only)

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; { echo "prefs-normal: $(stat -f "%z %m" "$HOME/Library/Preferences/$BUNDLE_ID.plist" 2>&1)"; echo "override-domain: $(defaults read $DOMAIN 2>&1 | tr "\n" " ")"; echo "savedState: $(ls -ld "$TMPDIR/$BUNDLE_ID.savedState" 2>&1)"; } > "$NOTES/prefs-before.txt"; ls -t "$HOME/Library/Logs/DiagnosticReports" | head -5 > "$NOTES/reports-before.txt"; { ps -ax -o pid=,command= | grep -F Virtualization.VirtualMachine | grep -v grep; } > "$NOTES/helpers-all-before.txt"; cat "$NOTES/prefs-before.txt" "$NOTES/reports-before.txt"; wc -l "$NOTES/helpers-all-before.txt"'
```

Keep these files: the end of the run compares them. `prefs-normal` is the size and mtime of the owner's own `com.example.VMRunner.plist`; it must be the same at the end.

## The sub-runs

Order: **A, then B1, then B2.** One at a time; never two apps. Before each launch: `bash "$TOOLS/budget.sh"` prints OK (at least 17 minutes left of the 50; STOP otherwise: the sub-run is not started and the report says so),
and `df -g /tmp` shows at least 40 GiB free.

| Sub-run | Machine | Defaults in the scratch domain (besides `runsControlService`) | What it answers |
|---|---|---|---|
| A | `win-a` | none (the capability on) | does a Windows machine start and how far does it get with the performance-monitoring emulation on (or what is the capability error, N2) |
| B1 | `win-b` | `DisablePrivateInterfaces` true | the start error of a Windows machine while private interfaces are off, word for word (an **expected** failure: no guest runs) |
| B2 | `win-b` (same, never booted) | `DisablePrivateInterfaces` true and `WindowsStartsWithoutPMU` true | how far the guest gets without the emulation |

### Procedure of a booted sub-run (A, B2; X is the label, NAME its machine)

**X1. The defaults** (the app reads them at its start, the app is not running now). A: `/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; defaults delete "$DOMAIN" DisablePrivateInterfaces 2>&1; defaults delete "$DOMAIN" WindowsStartsWithoutPMU 2>&1; defaults read "$DOMAIN"'`
(only `runsControlService` is left). B2: `defaults write "$DOMAIN" DisablePrivateInterfaces -bool true` and `defaults write "$DOMAIN" WindowsStartsWithoutPMU -bool true`, then `defaults read "$DOMAIN"` shows the three keys. Record which.

**X2. Tell the owner**, in the conversation, before the launch: the app's window will appear, probably behind other windows, and **the owner** brings it to the front (the agent never does); the window shows the machine `NAME` once it starts; the owner then follows the clock times that
step X5 prints. Nothing else is needed on screen.

**X3. Launch** (the first call also starts the 50-minute clock; note the time):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/launch.sh" X NAME'
```

(with X and NAME replaced). It prints `run=X machine=NAME id=<UUID> app=<pid> socket=ready launch=<epoch>` within a minute. If it prints that the app exited, read `$NOTES/X/app.log`: that is a result (record it), STOP the sub-run and go to X8. If the harness kills background processes when a call
returns, run the same command again with the tool's run-in-background option; the scripts do not change. Then list the machines the service sees, once (the token's `list` capability):
`/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; "$V" control list --socket "$SOCK" --token-file "$TOKEN"'` shows both machines, `stopped`, `windows` (and the approvals file now exists: `ls "$DATA"`). If the app shows a dialog, an open panel or a permission prompt (N4) instead of its window: read it with
`ax text` (`VMR_APP="$APP" "$TOOLS/ax" text <app pid>`), record the text, STOP the sub-run. Do not click it.

**X4. Start** (this call returns when the machine runs or the start failed, within 120 s):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/start.sh" X'
```

It prints the times, what `vmr control start` printed, and either the guest process (the helper's pid) or the line saying the app hosts the guest (N1). Exit 0 and a `running` answer: **T0** is the printed `answered` time. Otherwise:

- A: the text starts with `Windows needs the performance-monitoring emulation, which is unavailable:` -> the capability is off or unavailable on this Mac (N2, F26): that text, verbatim, is A's result; no guest runs; do `collect.sh A error`, then X8 (digest and quit), X10, and go on to B1 (X9 has nothing to ask).
- Any other failure (a missing file, a refused approval, a permission refusal, a timeout): record the text verbatim, `collect.sh X error`, X8, and **STOP the card** (no retry with another configuration: a change is a code change for the owner).

**X5. The owner's clock.** At once:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/schedule.sh" X'
```

and send the owner this, with the printed times filled in: "The machine runs since T0 = ... . **Look at the machine's window from ... to ... (2:00 to 3:00 after T0) and again from ... to ... (8:00 to 9:00 after T0)** for 60 seconds each time. Keep a note, with the wall-clock time, of which of these you saw
(one of: black window / firmware logo or text / Windows Boot Manager screen / 'Press any key to boot from CD or DVD' prompt / Windows Setup screen / error screen (write the text word for word) / other (describe)); anything else you notice at other times, with the time, is welcome. You may press a key in the window **only if you choose to**; if you do, note which key and when. The machine
is stopped at ... (T0 + 12:00) and the hard cap is 15 minutes after the launch. After the stop I will ask for your notes. If Setup shows anything about requirements, copy its words as you see them; I will not do anything about it." The agent presses nothing and says nothing about what to press.

**X6. Watch** (the agent only watches; sampler, watchdog and log stream are already running). Run each `waitto.sh` call with the tool's timeout set to 600000 ms, or in the background: a call can last up to 540 s.

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/waitto.sh" X 190; echo exit=$?'
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/collect.sh" X look1'
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/waitto.sh" X 550; echo exit=$?'
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/collect.sh" X look2'
```

(`exit=124` means "call again"; `exit=2` means the app is gone before that time: a crash or a kill, a result: go to X7 at once.) Each `collect.sh` records the machine's state, the window (title, size, flags), and the `ps` lines of the app and the helper.

**X7. The end.** The watchdog force-stops the machine at T0 + 12:00 (a power-off of an installer session: nothing in it is kept). Wait for it, then observe:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/waitto.sh" X 735; echo exit=$?'
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/collect.sh" X stopped'
```

The state reads `stopped` and the helper's `ps` line is gone. If the machine is not stopped by T0 + 13:00, run `"$V" control stop <id> --force --socket "$SOCK" --token-file "$TOKEN"` (recorded in the report as a backstop used), and if the app does not answer, `quit.sh` kills it (X8). The guest can also end earlier by itself or by the machine's own
runtime limit (T0 + 15:00 > 12:00, so the planned stop comes first): record whichever came first (`state.csv`, `watchdog.log`).

**X8. Digest, then quit the app.**

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; cd /; bash "$TOOLS/digest.sh" X'
/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; bash "$TOOLS/quit.sh" X'
```

Read the digest's output into the report (section "What to record"). `quit.sh` ends the sampler, the watchdog, the log stream and the app (no machine runs, so no quit alert appears), and checks that no framework guest process of the run is left. The files of `$NOTES/X/` stay until "Clean up"; the report quotes what it needs (200 lines at most).

**X9. The owner's notes.** Now, with nothing running, ask the owner for the notes of X5. Write them down **verbatim**, with the owner's own wall-clock times, converted next to them to T+ (`T0` from `start.times`). The report's table of looks is filled from these words and nothing else: a look the owner did not make is NOT SEEN.

**X10 (after A, before B1): reset for the next run.** The next machine is `win-b`, made before the first launch and never started (fresh disk, fresh firmware store, fresh identifier). Remove `win-a`'s folder, whose disk the guest wrote to: print its path from `ids.txt` and remove exactly that folder
(`rm -rf "/tmp/vmr-windows-run-<TS>/Machines/<UUID of win-a>.vm"`, the literal path), then `defaults delete "$DOMAIN" DisablePrivateInterfaces 2>&1; defaults delete "$DOMAIN" WindowsStartsWithoutPMU 2>&1; defaults read "$DOMAIN"` (both keys reset; only `runsControlService` is left), then `df -g /tmp | tail -1` (at least 40 GiB) and `ls "$DATA/Machines"` (only `win-b`'s folder).

### Sub-run B1: the start error with private interfaces off (no guest runs)

1. `/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; defaults write "$DOMAIN" DisablePrivateInterfaces -bool true; defaults read "$DOMAIN"'` shows `DisablePrivateInterfaces = 1` and `runsControlService = 1` (and no `WindowsStartsWithoutPMU`).
2. Budget check, then `launch.sh B1 win-b` (X3), then `start.sh B1` (X4). **Expected: exit 1** and the output of `vmr control start` carrying the error text of F25. Copy `$NOTES/B1/start.out` into the report **verbatim, character for character**, beside the expected text of F25, and say whether they are equal (a difference is a result, not a failure of the card).
3. `collect.sh B1 error` (while the app still runs: its `ax text` line is the alert the window shows, F27; the state reads `stopped`), then `digest.sh B1` (its log part must hold a `Start failed` line whose description is `<private>`, F27) and `quit.sh B1`.
4. The machine did not run, so its disk is untouched and **needs no reset**; B2 uses it.

### Sub-run B2: the same machine, the emulation off by the developer default

1. `/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; defaults write "$DOMAIN" WindowsStartsWithoutPMU -bool true; defaults read "$DOMAIN"'` shows the three keys (the kill switch stays on: the policy still denies the capability; the developer default is what lets the start go on, F24).
2. Budget check, free-space check, X2, then X3 to X9 with `X = B2`, `NAME = win-b`. **Expected: exit 0**, and the app's log (`logstream.txt`, `logshow.txt`) holds the notice of F24:
   `Windows starts without the performance-monitoring emulation (the developer default DisablePrivateInterfaces is on): WindowsStartsWithoutPMU is on`. Its absence is a result.

### What the owner does, in one place

Look at the window at T0 + 2:00 to 3:00 and T0 + 8:00 to 9:00 and report one of the seven categories (X5); the owner may press a key in the window only if the owner chooses to and says so; the agent never does. After the stop, the owner sends the notes. In sub-run B1 nothing is asked of the owner. The ISO is never touched by the owner either (no mounting, no opening).

## What to record (the report: `~/Developer/g-cqd/vmrunner-board/realguest-windows-report.md`)

Write the report in the style of the earlier real-guest reports: dated, "Seen = read from a log, file or output of this run. Inferred = my reading", one table per area, a deviations section, a cleanup section. Every claim row has: the claim, **how observed** (the file or output it comes from, quoted), **Basis** `SEEN` or `INFERRED`,
and the verdict `YES` / `NO` / `NOT SEEN`. A claim the evidence does not reach is NOT SEEN, never NO (for the owner's looks: a look not made is NOT SEEN). The template of its sections:

```
# Real-guest run: a Windows machine in the app (date, host, commit)

## 0. Summary (five lines at most: what booted how far with the emulation on and off, hang/crash, NVMe in Setup, app stability)
## 1. Host and inputs
H1 sw_vers, uname -m, hw.model, kern.osversion and IN/OUTSIDE the range (N2); the commit built (rev-parse HEAD) and that it was main; build exit=0 and its time; codesign flags and entitlements; bundle identifier and DOMAIN; the fact check's counts (step 2)
H2 the authorisation: the owner's words and the time; the exception to the 2 CPUs / 2048 MiB cap, quoted
H3 the media: path, size, mode; expected and seen SHA-256; ls/stat before and after (equal); referenced in place, not cloned (F18); no driver disc
H4 how the machines were made: by hand with the app's own framework calls (F3, F4) and why; whether the New Machine sheet offers Windows in this build (N7); the two config.json files as written; sparse disk figures (apparent / allocated); the approvals file made by the first load and no prompt
H5 the settings of each run: the keys of the scratch domain (defaults read), the control token's capabilities (never the secret), Accessibility available or not (N6)
## 2. Per sub-run (a column each for A, B1, B2; for every row the quoted line)
S1  launched: launch.sh's line; the control list (both machines, windows, stopped)
S2  the start: start.times and start.out verbatim; time from the start request to `running`
S3  B1 only: the error text verbatim beside the expected text of F25; equal or not; the alert text read through Accessibility (ax text); the log's `Start failed` line and its private description
S4  the capability: A: no error and no notice line (F24); B2: the notice line quoted; A on a build outside the range: the capability error quoted (N2)
S5  the process that hosts the guest: helper pid and its command, or "the app hosts it" (N1)
S6  the guest's devices as the app configured them: from config.json after the run (hasBooted, lastDisplay*) and "Starting display 1920x1200 ... fixed size" from the log
S7  the owner's looks (table below), with T+ times
S8  CPU: the digest's per-minute table for the helper and the app; peak resident set; sampling method (cumulative CPU time over 10 s, N8)
S9  disk: the digest's allocated size per minute; first growth; whether EFIVariables.fd changed (firmware wrote variables)
S10 hang (rule below), crash (the app gone before the planned stop; new crash-report file NAMES, never their content), the machine's state series (state.csv)
S11 stop: how it ended (planned force stop at T0+12:00 / the guest / the cap / a backstop), the helper gone, `quit.sh`'s output
## 3. The owner's looks (A, B2): look | planned window | wall-clock time the owner gives | T+ | category | the exact words of any error or Setup text | keys pressed by the owner, if any
## 4. Findings
Q1 Does a Windows machine start with the emulation on (A), and what is the error if not?   Q2 Is B1's error text the expected one, word for word?
Q3 How far does the guest get in A and in B2 (the furthest stage the owner saw, and when)?  Q4 What differs between A and B2 (stage, CPU, disk writes, firmware writes)?
Q5 Hang or crash in either?   Q6 Is the NVMe disk in Setup's disk list (the owner's words), or NOT SEEN if Setup was not reached?
Q7 Setup's requirement check, if the owner reached it: the words as observed. Nothing is done about it and nothing is suggested.   Q8 App stability: alive until the planned stop, errors and faults in the log, crash reports.
Q9 What the run could not answer, and what it would take.
## 5. Deviations from the card (every one: what, why)
## 6. Cleanup: what was removed (each path), what was left (the defaults file if it stayed, the report), the checks of "Clean up"
## 7. Not established from the code (N1 to N8): which were settled by the run, which stay open
```

Definitions used by the report (the card's own, chosen before the run, not facts of the framework): **hang** = the guest's process shows CPU at or above 300% (about three of the four cores) for at least 18 consecutive 10-second samples (180 s) **and** `Disk.img`'s allocated size grew by 1024 KiB or less over the same time; **busy and writing** = the same CPU with a larger growth; **idle** = under 20%. **Reached a stage** = only what the owner reported, with the time; the samples
can contradict a report but never create one. The digest prints the longest streak at or above 300%; the report decides the rule from the CSV files, quoting the rows.

## Stop conditions

- Not authorised; the ISO's hash does not match, or the system refuses to read it; less than 50 GiB free at P3 or less than 40 GiB before a sub-run; another VMRunner is running; any `/tmp/vmr-windows-run*` path exists; the domain `$DOMAIN` exists before the run; an organisation policy touches `AllowPrivateInterfaces` or `AllowControlService`; `main` does not hold the chain.
- The build or its verification fails; a fact-check string of F22 to F25 is missing; a disk image is not sparse.
- The app shows an open panel, an approval prompt, a permission prompt or an error dialog other than the expected start error: record its text (`ax text`), then stop that sub-run (X8). No retry with another configuration.
- `vmr control start` fails for a reason other than the expected capability error (X4): record it and stop the card.
- The app exits or crashes (a result: record the new crash report's file name, never its content): stop the sub-run, go to X8, and **do not** start another sub-run.
- Anything would need the agent to type, click, scroll, foreground a window, press a key for the owner or take any screenshot or capture; `ax` refuses a pid; Accessibility asks for a permission: ask the owner instead, change no permission.
- Anything would write to or read from the owner's library (`~/Library/Application Support/VMRunner`), one of the owner's machines, or signal a pid that this run did not record; anything would modify, move, copy, rename or mount the ISO.
- Anything in Setup asks for a step around its checks: the agent does not provide, describe or suggest one; it writes down what the owner reports and goes on to the stop.
- Time: 15 minutes in one sub-run (the watchdog enforces it), or 50 minutes since the first launch (`budget.sh`): go to X7/X8 and then "Clean up".

## Clean up (always, also after a stop)

1. Processes. The recorded pids are in `$NOTES/pids.txt` as `kind pid`. List what still runs and signal only those, children first: `/bin/bash --noprofile --norc -c '. /tmp/vmr-windows-run.env; while read kind pid; do if kill -0 $pid 2>/dev/null; then echo "$kind $pid children: $(pgrep -P $pid | tr "\n" " ")"; fi; done < "$NOTES/pids.txt"'`,
   then `kill -TERM` each of those (the sampler, the watchdog and the log stream first, the app last), wait up to 10 s each, `kill -KILL` what remains, in a second pass. A framework guest pid of the run still there 15 s after its app ended: `kill -TERM` that recorded pid. `pgrep -x VMRunner` prints nothing and
   `ps -ax | grep -F Virtualization.VirtualMachine` shows no process that is not in `$NOTES/helpers-all-before.txt`.
2. The override domain. With no app running: `defaults delete "$DOMAIN"` (it removes `runsControlService` and both developer keys); then `ls -l "$HOME/Library/Preferences/$DOMAIN.plist"`. If the file is still there (the preferences daemon writes an empty one back), say so in the report as left (size and time) and do not try to remove it by hand.
3. The owner's own domain is unchanged: `stat -f "%z %m" "$HOME/Library/Preferences/$BUNDLE_ID.plist"` equals the first line of `$NOTES/prefs-before.txt` (size and mtime); if not, record both and say what could have written it. The `$TMPDIR/$BUNDLE_ID.savedState` line of `prefs-before.txt` is unchanged.
4. **The ISO is as it was**: `ls -l`, `stat -f "%z %m %Sp"` equal to `$NOTES/iso-before.txt`, and `shasum -a 256` again equals `8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c`; `hdiutil info | grep -i -e vmr -e Windows11` prints nothing (nothing was mounted). It is **not** removed.
5. Remove the run's folders and files. Print the variables once (`cat /tmp/vmr-windows-run.env`) and write the removal with the **literal paths it shows** (a removal through shell variables is refused by the agent's own safety check, and a typo there would be costly): `rm -rf` of exactly the four paths
   `/tmp/vmr-windows-run-<TS>` (the data folder: both machines' remains, the token digest, the approvals file), `-tools`, `-notes` (the token file, the logs, the CSV files), then the worktree with `git -C ~/Developer/g-cqd/VMRunner worktree remove --force /tmp/vmr-windows-run-<TS>-src` and
   `git -C ~/Developer/g-cqd/VMRunner worktree prune`, and last `rm -f /tmp/vmr-windows-run.env`. Copy nothing into the repository; the report quotes what it needs from the notes **before** this step. Then check: `ls -d /tmp/vmr-windows-run*` says `No such file`,
   `git -C ~/Developer/g-cqd/VMRunner worktree list` shows only the main checkout, and `git -C ~/Developer/g-cqd/VMRunner status --short` shows nothing new (the build wrote only into the worktree).
6. `df -g /tmp` is back near the figure at P3 (the build and the guest's writes are gone). The report says what was removed and what was left (the defaults file if it stayed; the report itself; the ISO untouched).

## Verification of this card (done when it was written; nothing was built or started, no repository was edited)

- Every fact above was read from the commit `7145332` with `git show` and `git grep` (the clone's working tree was not read), at the lines given.
- The scripts and the JSON block of this card were extracted from this file and checked in a scratch folder (deleted afterwards): `bash -n` on each script, `swiftc -parse` on `mkefi.swift`, `plutil -extract` and `plutil -p` on the config, and `digest.sh` run on a synthetic run folder (a CPU series with a 300-second busy stretch, a disk series that starts growing at T+180 s, a firmware store whose mtime changes at T+60 s: the tables came out as expected). No app, no guest and no `vmr` call was made.
- Not verified, because it needs the built app or a guest: that the control service accepts the hand-written token file (the format is the one the store writes: `ControlToken.swift:20-41`, `ControlTokenStore.swift:94-99`), that `vmr control start` prints the error as the code says (N5), that the guest's process is the framework's helper (N1), the system's response to the app reading the ISO in the Downloads folder (N4), Accessibility's availability (N6), and everything the guest does.
