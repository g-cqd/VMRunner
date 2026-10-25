---
date: 2026-10-25
question: "Can a firmware image supplied through the EFI boot loader's private ROM selector give a Windows on ARM guest a display during boot?"
feeds: [roadmap 0015, roadmap 0029, ADR-0010, ADR-0019]
---
# A framebuffer for Windows on ARM through a supplied firmware image

**Status: design only; nothing is implemented and no call to the selector was made.** This note says what a later spike
would test, how it would know it worked, and what it would put at risk. Host: macOS 27.0.1 (build 26A434), SDK 27.0.

## The problem

`docs/research/windows-on-arm-2026-10.md` states that Windows Boot Manager "needs a linear UEFI framebuffer that Apple's
firmware does not provide", and lists the way another party solved it: a small EFI driver, loaded from the guest's disk
by a boot shim, that backs the graphics output protocol with reserved RAM. That document does not say which protocol the
framework's firmware lacks or implements partly, how that was found, or whether the finding holds on macOS 27: its source
is a third party's code, read, not run here. Treat "the firmware offers no display output that Windows' boot display
driver can use" as the reported cause, not as a fact measured on this host.

Without a display, a Windows guest can start (with the performance monitoring capability, see
`docs/research/private-apis-2026-10.md`) and still show the owner nothing: no boot manager, no installer, no way to
choose a boot entry. The guest-side driver route puts code on the guest's disk, so it needs a prepared disk and works only
after the firmware has found that disk. A firmware that already draws would work before any disk is read.

## The route

The framework's EFI boot loader class has a private pair of selectors, read with `class_getInstanceMethod` and
`method_getTypeEncoding` (nothing called) on the host above:

| Selector | Type encoding | With digits stripped |
|---|---|---|
| `_setROMImageURL:` | `v24@0:8@16` | `v@:@` |
| `_ROMImageURL` | `@16@0:8` | `@@:` |

Both exist on `VZEFIBootLoader`. The argument is an object; its class is not in the encoding. A URL is inferred from the
name and has to be confirmed.

The idea: the app hands the boot loader a firmware image for the guest, of its own making, that includes the display
output the framework's firmware lacks. Two ways to get the image, to be chosen by the spike:

1. **Built from source** by a later tooling command from a pinned revision of an open-source UEFI firmware, with the
   display output added. No download in app code; the build is the developer's step, not the user's.
2. **A pinned artefact**: a file built once, stored with the app's resources, checked against a recorded SHA-256 before
   every use, and never fetched at run time.

Either way the call goes through one capability of the registry that ADR-0019 describes (below), never from the
machine-building code.

## What is unknown

1. Whether the selector means "replace the firmware" or "add a module to it". The name says image, the effect is unread.
2. What class the argument must be, whether it is copied or kept by reference, and whether the file must stay in place
   while the machine runs.
3. Whether `validate()` accepts a configuration with the URL set, and what it says for a missing, empty or unreadable file.
4. The image's format: a full firmware volume, a bare volume of the same layout as the framework's own, or something else.
5. Whether the framework's own variable store (`VZEFIVariableStore`) still works with a different firmware: its layout
   and variable names are the framework's.
6. Whether the framework starts the guest's CPU at an address and with a memory map that a firmware built elsewhere can use.
7. Whether the display device the guest then sees is one the framework offers (the framework's graphics device, or the
   custom device of macOS 27) and how the supplied firmware reaches it.
8. Whether any of this changed between macOS 26 and 27.

## Acceptance criteria for the spike

Each is checked by a throwaway program or the owner's authorised run, and recorded with the exact error text; the
spike's own tests start no machine.

1. **Selector contract.** On the running build the setter resolves on `VZEFIBootLoader`, its encoding is `v@:@` after
   stripping digits, the getter is `@@:`, and setting a URL then reading it back returns the same URL. Anything else is
   "unavailable".
2. **Validation.** `VZVirtualMachineConfiguration.validate()` accepts a Windows-shaped configuration (generic platform,
   EFI boot loader with a variable store, the NVMe disk, USB input) with the ROM URL set to a readable file, and refuses
   with a clear message when the file is missing. Record the domain, code and description of both.
3. **A real guest shows the boot manager.** In an owner-run session, a Windows installer medium reaches Windows Boot
   Manager or the installer's first screen on the machine's window, with the supplied image and without any
   code on the guest's disk. A picture of the window goes in the run report.
4. **The original firmware path is unchanged.** With the capability off (killed, forced off by policy, or the OS build
   outside its range) the setter is never called, a Linux guest still boots with the framework's firmware exactly as
   before: the configuration it is given is the one it is given today.
5. **Variable store.** A machine started twice with the supplied image keeps its boot entries between the two runs;
   a machine moved back to the framework's firmware still starts (or is told clearly that its store no longer matches).
6. **Failure is clear.** A missing, truncated or wrongly hashed image gives a start error that names the capability and
   the file, and starts nothing.

## Risks

- **The selector is private.** It can change, vanish or change meaning in any build. It would be a capability with an OS
  build range, a validator and a kill switch, like every other private capability; a wrong call can crash the process,
  which a handler does not catch.
- **It replaces the platform's firmware, if the first unknown resolves that way.** Everything the framework's firmware
  does for the guest then becomes the supplied image's job: boot services, the variable store, the memory map, the
  hand-off to the loader. A fault in it is a fault in the guest's whole boot, and the framework's tests do not cover it.
- **Secure Boot and variable-store compatibility.** The Windows machine runs with Secure Boot off. A different firmware
  may keep its keys and boot entries in a different layout, or in the same file in a different way; the framework's store
  could be unreadable to it, or be damaged by it. A machine may then be unable to go back.
- **Licensing.** A firmware image built from source carries the licence of that source and of every module added; those
  terms apply to a file the app ships, and the notices have to ship with it. A pinned artefact has to record where it
  came from. This note decides nothing about them; the spike must list them before any file enters the repository.
- **Signing and trust.** The image is code run before everything else in the guest. It would be hashed and pinned, the
  expected hash lives in the app, and a file is used only when its hash matches. Whether the framework or the host's
  code-signing rules check the image is unknown.
- **Distribution.** Like the other private capability, it keeps the build out of the Mac App Store, and the experimental
  label of the Windows support stays.
- **It does not change what Windows Setup requires.** The display only lets the owner see the screen. The app provides no
  virtual TPM and works around no requirement.
- **Maintenance.** A firmware built from source is a second thing to rebuild, review and keep in step with the framework.

## As a capability

A new entry in the registry of ADR-0019 (in use for Windows since [ADR-0059](../adr/0059-windows-on-arm-is-supported-with-its-one-private-interface-behind-a-fail-closed-module.md)), beside the performance monitoring one, that:

- has an id of its own, an OS-build range, a resolver (runtime lookup of the selector through its name string), a validator
  (the type encoding with digits stripped, `v@:@`, and the getter `@@:`), and a kill switch;
- fails closed: unresolved, mismatching, out of range, killed, or a read-back that differs from what was set means
  "unavailable", with the reason for the start error and the exposure lines;
- is forced off in the Hardened and Isolated postures and by a managed key, and appears in the exposure lines and the help
  as "uses unsupported API";
- is used only for a Windows machine, and only when the machine asks for it. No other guest ever reaches it.

## Not decided

Whether to do the spike at all, which of the two routes to take, and any user-facing setting. If the spike fails any of
criteria 1 to 3, the guest-side route in the first study remains the only one found; if it passes, a decision record
would follow before any code lands.
