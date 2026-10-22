---
status: in-progress
blocked-by: []
date: 2026-10-22
decision: ADR-0034
---
# 0038 — The Linux boot display: firmware and boot loader text must be legible

**Priority: very high, right after roadmap 0037.** In a Linux guest the boot loader (GRUB) and the firmware screens appear tiny:
the glyphs are drawn at a fixed pixel size on a framebuffer that is far larger than the window shows comfortably, so the
text is unreadable on a Retina display. ADR-0002 already says the Linux starting width is capped at 1280 pixels so that
firmware text stays legible; the owner still sees tiny text, so either the cap is not reached on some path or the boot loader
picks its own mode.

## What can and cannot be promised

- **GPU acceleration cannot apply at this stage.** The firmware and the boot loader draw into a plain framebuffer
  (the firmware's graphics output) before any guest driver exists; there is no acceleration to enable. Linux guests get no 3D
  acceleration from the framework at all (ADR-0014; roadmap 0014 is blocked on a macOS 27 host). What can be fixed is the
  resolution and scale of that framebuffer, and the guest's own console font after boot.
- The boot loader's graphics mode is chosen inside the guest by its own configuration (GRUB's `GRUB_GFXMODE`,
  `GRUB_GFXPAYLOAD_LINUX`) and by what the firmware offers; this app controls only the scanout the firmware sees.

## Hypotheses to test, in order

1. **A remembered size overrides the cap.** The last display size is remembered per machine and `fitsWindowAtStart` applies at
   start; a size remembered from a large window (the guest follows the window once Linux runs) may be reused for the next
   boot, so the firmware starts on a framebuffer of several thousand pixels.
2. **The cap applies to width only on some paths** (a fixed preset, a saved machine state, a changed density setting, a
   restored snapshot or duplicate).
3. **`pixelsPerPoint` above 1** multiplies the scanout beyond the cap.
4. **The firmware offers several modes** and the boot loader picks the largest instead of the scanout's; the app cannot change
   that, but it can offer a mode list that makes the right one the largest.
5. **After boot the console font** is tiny because the kernel console sizes the font by pixel count; a guest-side setting
   (`fbcon=font:`) or a larger-pixel console is needed, which the help can say.

## Findings (2026-10-22, from the code and unit tests; no guest was started)

The scanout handed to `VZVirtioGraphicsScanoutConfiguration` is built in one place (`ConfigurationBuilder.configureLinux`) from
the size `VMController.start` computes. That computation is now `StartDisplay.size` and is called with realistic inputs in
`DisplaySizingTests`: a 1800 × 1100 point window, a remembered 3200 × 2000, one and two pixels per point, match-window on and
off, a duplicate, a restored state.

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| 1 | A remembered size overrides the cap | **Refuted** | `lastDisplayWidth/Height` are written in one place, a cold boot in `VMController.start`, with the start size already computed, and read in one place, to restore a saved state. The size the guest follows the window to (`DisplayResizer`, now `DisplayFollower`) has no access to the configuration and is never written back. A remembered 3200 × 2000 gives a cold start of 1280 × 782 (`aRememberedSizeIsNotTheNextColdBootsStartingSize`) |
| 2 | The cap applies on some paths only | **True, for a fixed size and for a cold boot after a restore** | Only the match-window branch was capped. A preset or custom size (2560 × 1600, 1920 × 1080 are in the editor's list) and the configured size used when no window size is known went to the firmware as they were. Fixed in the second commit, with five cases that failed before. A later pass over every stored combination (fixed presets, a remembered 3456 × 2234, match window and following on and off, one to three pixels per point, no window) found one more path, in the controller and not in `StartDisplay`: a start with a saved state builds the machine on the remembered size, and when the restore failed (or the configuration could not be restored at all) the cold boot reused that machine, so the firmware got the remembered size with no cap. The cold boot now decides its display again and remembers it (`MachineStartTests`, two cases that failed before). Everything else a cold start can read from a stored configuration stays at or under 1280 pixels wide, except a saved state that restores at its remembered size (by design, ADR-0034) and a fixed size with following switched off (by design). A duplicate forgets the remembered size and starts on the window (`LibraryTests`); restoring a snapshot swaps the disk and firmware variables only, discards any saved state and so cold boots on the same path; a changed density setting reaches Linux as `pixelsPerPoint` only |
| 3 | `pixelsPerPoint` above 1 multiplies the scanout beyond the cap | **Not at the start; yes after it** | The start is capped after the scale (1800 × 1100 points at 2 gives 1280 × 782). The follow-the-window code multiplied the view by the scale with no cap, by design, but did it 150 ms after the first layout, not after the boot |
| 4 | The firmware offers several modes and GRUB picks one | **Not decidable without a guest** | The framework documents the scanout size and that a guest "may or may not respond" to a new size; it does not document how the firmware picks its graphics mode. The machine's EFI variable store persists across boots, and whether the firmware keeps a mode there is unknown |
| 5 | The console font is tiny after boot | **Guest-side** | The help now names the exact settings (`fbcon=font:TER16x32`, `console-setup`) |

A sixth cause, not in the list, is the most likely one for a machine on default settings, where the start is already capped:
the follow-the-window code requested the window's full size (1800 × 1100 points, 3600 × 2200 at 2×) 150 ms after the first
layout, while the virtual machine was still starting, and swallowed a refusal. If the firmware reads its display after that
request, it starts on the window's size; if before, it is unaffected. Which of the two happens is not known. The new policy
asks for nothing until ten seconds after a cold boot (ADR-0034), so the firmware reads the capped size either way; it was
not possible to show on a guest that this was the owner's cause.

What was done (atomic commits): the start size is one tested function; a fixed size is capped too; the follow-the-window
policy is pure (`DisplayFollower`) and waits for the firmware; the machine view reports every frame change and writes its
settings only when they differ, with `--display-diagnostics` to log the sizes at each step; the help and the editor say what is
guest-side and that a suspended machine resumes at the size it started with. The remembered-size and ADR-0002 text that said a
size change discards a saved state was wrong and is corrected in place.

### What the framework allows

- `VZVirtioGraphicsScanoutConfiguration` takes a width and a height and nothing else; `VZGraphicsDisplay.reconfigure(sizeInPixels:)`
  changes them later and returns no error when the guest ignores the new size.
- `VZVirtualMachineView.automaticallyReconfiguresDisplay` is off by default and is documented as reconfiguring the display "to
  match the host display environment" when the view changes; only one view per display honours it. It is on for macOS guests
  only. Turning it on for Linux would reconfigure at the first layout, bypassing the cap and the hold, and the documentation
  does not say that a Linux guest then receives the view's size in points. It is not enabled; doing so needs a guest.
- `VZSpiceAgentPortAttachment` carries the clipboard only (its documentation lists nothing else); a resize does not go through
  it. Presumably the guest's virtio-GPU driver reads the size the framework reports; that is not documented and was not verified.

## Done when

1. The scanout size at start is computed by one pure function with tests covering the cap, the remembered size, the presets,
   density, snapshots, duplicates and saved states; the starting size for a Linux guest never exceeds the cap, whatever was
   remembered, and the guest still follows the window after boot. **Done**, except the single documented exceptions of ADR-0034
   (a saved state restores at its remembered size; a fixed size with following switched off is kept).
2. The owner confirms on one Linux guest (the installer, the boot loader menu, the first console) that text is legible at a
   Retina display and at an external display, and the numbers (scanout size, window points) are in the diary. **Open**.
3. The help says what is guest-side (boot loader mode, console font) with the exact settings, and what is not possible
   (acceleration before the guest's driver loads). **Done** (topic "Small text at boot (Linux)").

## Owner confirmation

Use the release app (`swift run vmr build-app`), a Linux installer guest (Alpine or Ubuntu from the New Machine sheet), NAT or
Filtered networking, and a machine with no suspended state. The numbers below are logged without any launch argument; read
them with the two commands of "Reading the always-on lines". Add `--display-diagnostics` (`open VMRunner.app --args
--display-diagnostics`) only for the per-layout tracing.

1. **Before starting**, note the window's size in points and the display's backing scale; the `Starting display` line prints both
   once the machine starts (`host screen scale 2.0`), and the `--display-diagnostics` lines earlier (`window … pt, backing scale
   2.0`). Do the same on the external display.
2. **Start the machine** and look, in this order, at the firmware screens, the boot loader menu and the installer's first console.
   For each, say whether the text is legible without leaning in, and whether the picture changes size while it is on screen
   (note the time since Start; the policy asks the guest for the window's size ten seconds after the cold boot).
3. **Report these numbers**: the `Starting display` line (the scanout size, the window points, the host screen scale, the rule);
   the `lastDisplayWidth` and `lastDisplayHeight` in `~/Library/Application Support/VMRunner/Machines/<id>.vm/config.json`; and
   every `Display resize:` line with its time (when the guest was asked, and whether it responded). All of them are
   logged without the launch argument.
4. **Repeat** with Resolution set to a preset of 2560 × 1600 and "Resize guest display with window" on (expected start: 1280 × 800),
   and with it off (expected start: 2560 × 1600 and small text, by design). Repeat with Guest pixels per point at 2×.
5. **After boot**, resize the window, maximise it and enter and leave full screen: the guest should follow, and the picture
   should fill the window.
6. **Suspend and resume** the machine and say whether it resumes at the size it started with, and whether anything is reported.
7. If the text is still small at 1280 pixels wide, apply the guest settings of the help topic one at a time (GRUB mode, then
   console font) and report which one changed what.

### Reading the always-on lines

These lines need no launch argument. They are notices, which the unified log keeps on disk, so they can be read after the fact
or while the app runs:

```sh
log show --last 10m --predicate 'category == "display"' --info
log stream --level info --predicate 'category == "display"'
```

Four kinds of line matter (sizes are pixels, window sizes are points; nothing identifies a machine or a path):

1. **`Starting display W×H px for a window of W×H pt; host screen scale S, guest pixels per point P; source …, width cap …,
   remembered size …; match window …, follows window …, restoring …`**: the scanout the firmware is given, and why. `source` is
   `window`, `fixed size`, `configured size, no usable window` or `saved state`. `width cap` is `applied` (the size was reduced
   to 1280 pixels wide), `in force, not needed` (already within it) or `does not apply` (macOS, a saved state, or a fixed size
   with following switched off). `remembered size` is `ignored` (a cold start never uses it), `used` (a saved state) or `none`.
   A second `Starting display` line in one run, with `restoring false`, means the restore failed or could not happen and the
   machine booted cold on the size a cold start has.
2. **`Display resize: guest responded: asked W×H px, the framework reports W×H px`**: the framework reported the end of the
   reconfiguration, so frames arrived at the requested size. The guest's driver used the size; a reported size that differs
   from the asked one means the guest settled on another.
3. **`Display resize: guest did not respond within 2.0 seconds: asked W×H px, the framework reports W×H px`**: the framework
   accepted the request (it returns no error either way) and no end of the reconfiguration came in two seconds. The guest did
   not use the size, and the machine view shows "The guest ignored the display resize (firmware and boot loader screens
   cannot follow the window)." until the next response. A `guest responded` line after it means the guest answered late. Expected
   while the firmware, the boot loader or the installer's early console is on screen; for a guest that has booted, it means
   its display driver does not act on the size, which is a finding to report. The size the framework reports is the display's
   size at that moment: for an ignored request it is normally still the size from before.
4. **`Display resize: asking again (repeat N) for W×H px: the guest has not answered`**: an ignored request is repeated after 2,
   4, 8 and 16 seconds and then every 30 seconds, because the guest's display driver may load after the firmware and the boot
   loader and only then answer. Each repeat is followed by `guest responded` (the repeats stop and the note in the machine view
   goes) or by another `guest did not respond`. The repeats also stop when the window gets another size (the count starts over),
   when the display shows the wanted size by itself (`display now shows W×H px, nothing left to ask`), and when the machine
   stops. If a booted guest answers the first repeat after the boot loader, the guest's driver was what was missing before.

A `refused` line (error level) is the framework rejecting the request; it is retried. No `Display resize` line after a window
change means nothing was asked: the first ten seconds of a cold boot, a view under 64 points, "Resize guest display with
window" off, a macOS guest (the framework resizes it and the follower does not take part), or the display already had the size
(`--display-diagnostics` shows which).
