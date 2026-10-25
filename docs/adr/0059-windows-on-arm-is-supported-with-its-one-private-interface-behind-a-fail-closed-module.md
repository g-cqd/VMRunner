---
status: accepted
date: 2026-10-25
supersedes: ADR-0010
---
# 0059 — Windows on ARM is supported, with its one private interface behind a fail-closed module

## Context

ADR-0010 recorded that Windows guests are not supported, because a Windows ARM guest needs a private switch the framework does
not document (performance-monitoring emulation on the generic platform configuration) and the framework has no virtual TPM.
ADR-0019 then decided how private API may be used at all: one module, capabilities with a build range, a validator and a kill
switch, off in the Hardened preset. It did not say whether Windows is revisited.

Two things changed. The owner decided to try Windows on ARM as an experimental guest. And the private switch was probed on
macOS 27.0.1 (build 26A434) without starting a virtual machine: the setter `_setPerformanceMonitoringUnitEmulationEnabled:`
(type encoding `v20@0:8B16`) and the getter `_performanceMonitoringUnitEmulationEnabled` (`B16@0:8`) exist on
`VZGenericPlatformConfiguration`; a fresh configuration reads false, true after the setter was called with true, and false
again after it was called with false. Whether a Windows guest then boots was not run. The research
(`docs/research/windows-on-arm-2026-10.md`) and the acceleration assessment of 2026-10-24 say what a guest needs besides that
switch and what no public API gives.

## Decision

1. **Windows on ARM is supported as experimental.** `GuestOS` gains a Windows kind of its own. The help, the New Machine sheet
   and the exposure summary say "experimental" and what it means. ADR-0010 is superseded.
2. **One private interface, behind the typed module of ADR-0019.** The only private call is the PMU switch on the generic
   platform configuration. It lives in a library target, `PrivateInterfaces`, that holds a capability registry: each
   capability has an id, a range of OS builds (`kern.osversion`), a resolver (an Objective-C runtime lookup by selector
   name), a validator (the method's type encoding, digits stripped, must equal the declared one, `v@:B` for the setter), a
   fallback (unavailable, with a reason) and a kill switch. The setter is called through the method's implementation, then the
   getter is read back; any mismatch makes the capability unavailable. Nothing else in the repository looks up a selector by
   name. This starts the module ADR-0019 decided; it differs from that ADR in one point: the module calls the Objective-C
   runtime itself and imports no interop package, because one capability needs a few lines, not a dependency (ADR-0001).
3. **Policy.** The capability is forced off in the Hardened and Isolated postures, can be turned off by a managed preference,
   and is listed in the exposure summary and the help as using an interface the framework does not document. A kill switch
   in the app's settings turns it off for the user.
4. **A Windows machine does not start without the capability.** If it is unavailable or off (posture, managed key, kill
   switch, OS build, or a failed validation), the start fails with a message that names the capability and the reason. One
   developer default, `WindowsStartsWithoutPMU` (bool, default false, in the app's defaults domain, read once at each
   start like `CustomGPUInput`), lets an owner start anyway to watch what happens; it is documented as developer-only.
5. **The machine.** Generic platform and EFI boot loader (the Linux path), no cloud-init seed, no serial-console assumption,
   no Rosetta, Secure Boot off, an NVMe main disk (an inbox Windows driver exists for it, which is untested on this
   framework), a USB keyboard and pointer, a virtio network device, audio as the existing setting but off by default for
   Windows (it has no driver for the device), and the PMU capability on. The installer ISO and an optional driver ISO are
   attached as read-only USB mass-storage devices.
6. **The New Machine preset for Windows.** 4 CPUs, 8 GiB of memory, a 64 GiB sparse NVMe disk (the Windows disk range starts
   at 64), NAT, 1920 x 1200, a slot for the installer ISO (a local file only, with an optional expected SHA-256 checked
   before the file is used), a second slot for a driver ISO, and a requirements panel.
7. **No virtual TPM, and the app does not hide it.** The framework has no virtual TPM, so this machine has none. The panel
   says: "Windows 11 Setup checks for a TPM 2.0 device. This machine has none: the app does not provide one and does not work
   around the check. Meeting Windows Setup's requirements and the licence terms is up to you." The app provides the machine,
   the media slots, this text and verification of the files the user picks. It does not alter the installer, generate
   answer or unattended-setup files, or change what Windows Setup checks.
8. **Licences and media.** Each Windows installation needs its own licence. Insider Preview builds follow the Insider
   Program's terms and expire; retail builds do not. The app downloads nothing for Windows: the user picks local files.
   Windows has no built-in driver for the virtio network device, so networking needs a driver disc the user supplies.
9. **Limits, stated plainly.** No suspend or saved state for Windows (nothing verified it with a private option set). No
   custom GPU for Windows: no signed ARM64 3D driver exists, and a custom virtio device is documented for Linux guests only;
   the display is the framework's. No audio by default. No shared-folder or guest-agent promise. Nested virtualization is
   reported to hang and is not offered.
10. **Distribution.** Developer ID, notarized. A build that carries a private interface is not eligible for the Mac App
    Store (guideline 2.5.1: public APIs only), and stays so while this capability is in the app.

## Consequences

The root package gains `PrivateInterfaces` and its tests; the app links it and nothing else does, and tests keep selector
lookups out of every other target. A contract test records, per OS build, the selectors it found and their encodings, and
skips where the selector is absent; the fail-closed paths are tested with a fake resolver, so they run everywhere. A new
macOS build outside the registered range turns the capability off until it is probed and the range is widened on purpose.
The Windows kind reaches the picker, the builder and the help in later changes, each on its own; until the builder exists
a Windows machine cannot be started.

The release process notes the App Store ineligibility. The selectors the study saw next to the PMU switch
(fine-grained traps emulation, the virtualization host extension, a guest type, a firmware image URL on the EFI boot loader)
are not used and not registered; each would be its own capability with its own probe.

## What this does not decide

Whether a Windows guest boots with the framework's own display, which depends on the firmware's framebuffer and has not been
run. A guest-side display driver, a firmware shim, drivers injected into the installer, or an answer file are not part of
this decision and not planned. Whether the capability widens to macOS 26 builds (it was probed on macOS 27 only). Acceleration
for Windows (assessment of 2026-10-24: blocked upstream). Any other private capability, the Seatbelt call included.
