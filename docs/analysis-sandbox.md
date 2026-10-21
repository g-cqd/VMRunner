# Using VMRunner as an analysis and agent sandbox

**Context.** The use case is sandbox analysis, privacy, and letting an AI agent run freely inside a contained machine.
Two separate goals follow: (1) **contain** the guest, and (2) **limit what the guest can learn** about the host, including
whether it is virtualized. This note records what is possible; it is honest about what cannot be hidden.

## Containment (built or planned)

- Security profiles (Contained, Isolated, Hardened), the exposure summary, disposable machines (copy-on-write clones deleted
  on stop), snapshots, runtime limits, no suspend, Secure Boot for Linux on macOS 27+ hosts.
- A network policy engine (allow-lists and deny-lists by IP, port, domain, connection, and http URL) and a user-mode network
  stack to enforce it; see `docs/automation.md` for the control plane.
- Host information is **not** shared with the guest by default; a planned, per-category opt-in would publish selected host
  facts (battery, power source, thermal state, network path) through a read-only share.

## What the guest can still tell about being virtualized (cannot be changed from the host)

These come from the Virtualization framework and the OS, not from app settings:

- **macOS guests** run under a hypervisor, which the kernel reports to the guest (`kern.hv_vmm_present`), and present the
  fixed virtual hardware model from the restore image (`VirtualMac2,1`), with Apple's paravirtual devices.
- **Linux guests** see virtio devices and the platform strings the Apple UEFI firmware provides (reported to include an
  Apple virtualization platform name; not verified here).
- Timing, instruction behaviour, and the virtual CPU model reveal virtualization to a determined probe.

So **concealment is only ever partial** with this framework. The framework is closed; a different hypervisor would offer
different knobs, at the cost of leaving VZ.

## What the app can legitimately tune

- **Resource realism:** analysis targets often judge a machine by its size; sensible presets (several cores, 8 GB or more of
  memory, a large disk) avoid the "tiny sandbox" signal. Already configurable.
- **Network identity:** per-machine MAC address (fixed, or re-randomised); the vendor prefix can be chosen. The virtio block
  device identifier (up to 20 ASCII bytes) is settable; an NVMe controller can present a disk without the virtio storage
  signature on Linux guests (`VZNVMExpressControllerDeviceConfiguration`, generic platform only).
- **Fresh identity per run:** a new machine identifier and MAC for each start of a disposable machine, so runs cannot be
  correlated by hardware identity.
- **Less host leakage:** no clipboard, shared folders, microphone, host-info sharing, or host time zone; the exposure summary
  shows what is open.

Not planned: anything whose purpose is to defeat detection run by someone else on a service you do not control (anti-cheat,
anti-fraud, DRM).
