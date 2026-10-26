# Emulated TPM 2.0 for Windows ARM — feasibility, 2026-10-26

Status: paused at the owner's request on 2026-10-26; no further TPM work is scheduled. Read-only research. No TPM emulator installed, built, started or attached. No additional private interface called. No Windows recognition or Setup compatibility is claimed.

## Conclusion

A software TPM command engine is feasible. Making it appear as a **normal TPM to an unmodified Windows ARM installer under Virtualization.framework** is the unsolved part. The current public API provides custom **Virtio** devices, not arbitrary platform devices, ACPI table injection, or register-level MMIO interception. An emulator process alone cannot fill that gap.

There is a research route worth investigating: a custom device with shared memory, plus a guest firmware component that exposes the standard TPM platform interface and discovery information. Whether the existing shared-memory API can implement the required register semantics is unproven. It is not a ready-to-wire feature, and it would not fix the independently observed early helper crash.

## Evidence and sources

### Installed Apple SDK 27.0

Read on macOS 27.0.1, build 26A434. Headers under the active Xcode SDK's `System/Library/Frameworks/Virtualization.framework/Headers`:

- `VZVirtualMachineConfiguration.h`: customVirtioDevices, available macOS 27. No TPM configuration property found.
- `VZCustomVirtioDeviceConfiguration.h`: Virtio deviceID, PCI class/subclass, virtqueues, feature negotiation, provider, device-specific configuration, shared memory regions. Changing the PCI class does not change the transport into a native TPM.
- `VZCustomVirtioDevice.h`: virtqueue access and valid guest-RAM mappings, configuration updates, reset. No arbitrary MMIO access callback or ACPI injection method is exposed.
- `VZVirtioSharedMemoryRegionConfiguration.h`: memory continuously shared between device implementation and guest, advertised as a Virtio shared-memory region.
- `VZVirtioSharedMemoryRegion.h`: host memory can be mapped/unmapped, aligned to host page size. This is not evidence of a callback on each guest register access.
- `VZGenericPlatformConfiguration.h`: no public TPM or ACPI construction hook found.

These are statements about the public SDK, not proof that no undocumented internal mechanism exists. The latter has not been established and no new private selector was probed or called.

### Public source and documentation, retrieved 2026-10-26

1. [TPM emulator overview](https://github.com/stefanberger/swtpm/blob/master/README): a software process provides socket frontends to a TPM implementation library. This supplies command handling, not guest hardware discovery.
2. [TPM library](https://github.com/stefanberger/libtpms): candidate command engine. No local build or macOS portability validation performed. Dependencies, licensing, distribution and maintenance need assessment before adopting it.
3. [Virtual machine TPM interfaces](https://github.com/qemu/qemu/blob/master/docs/specs/tpm.rst): explicitly separates frontend hardware interface from backend emulator. Documents TIS and CRB MMIO, ACPI TPM2 discovery, firmware initialization, persistent state, and an ARM platform frontend. These are upstream-source capabilities, not capabilities verified in a locally installed binary.
4. [ARM ACPI implementation](https://github.com/qemu/qemu/blob/master/hw/arm/virt-acpi-build.c), `acpi_dsdt_add_tpm`: publishes a `MSFT0101` device, `_STA`, `_CRS` memory resources, and physical-presence information. This illustrates what platform integration entails; adding only a socket backend is insufficient.
5. [Microsoft TPM recommendations](https://learn.microsoft.com/en-us/windows/security/hardware-security/tpm/tpm-recommendations): emphasizes hardware/firmware integration and TPM 2.0 requirements. It is not evidence that a proposed custom Virtio implementation is accepted by Windows.

Upstream master URLs are mutable. A prototype must pin exact source revisions and dependency hashes before building. Two attempted Microsoft links under the older device-experiences path returned 404 and are not used as evidence.

No swtpm, tpm2_getcap or qemu-system-aarch64 executable was found on PATH during this investigation. No installation was attempted.

## What a complete implementation must supply

| Layer | Work | Current status |
|---|---|---|
| TPM 2.0 command engine | Standards-conforming commands, keys, PCRs, NV storage, random generation and lifecycle | Existing engines are candidates; none evaluated locally |
| Guest interface | Correct TIS/FIFO or CRB behaviour, resources, locality, cancellation, reset and memory ordering | No public native-device frontend found in VZ |
| Discovery | Suitable ACPI device/resources and TPM2 table for the chosen interface | No public ACPI injection hook found |
| Firmware | Startup and UEFI TCG2 services; measurements and event log for measured boot; consistent handoff | Not implemented or validated |
| Windows | Inbox driver binding, TPM version/readiness, startup/reboot and provisioning | Entirely untested |
| Persistence | Per-machine identity and NV state; power-loss-safe writes; isolation and protection at rest | No model exists in VMRunner |
| Clone/backup policy | Consistent disk/EFI/TPM state; deliberate handling of cloned identity and rollback | Must be designed before user data is entrusted to it |

Enumeration or a successful GetCapability does not establish complete firmware integration, measured boot, attestation, compliance, or safe encrypted-disk recovery. A host software TPM is not equivalent to a discrete physical TPM's trust boundary.

## Candidate approaches

### 1. Native TPM frontend in a different VMM

Technically the clearest established architecture: a VMM controls MMIO and ACPI, and connects its TPM frontend to the emulator backend. This is a separate VM engine/integration project, not a small addition to the current VZ builder. Nothing was installed or booted to validate it here.

### 2. Custom Virtio command transport under VZ

Plausible for a research guest with an explicitly written driver. The public custom-device API can carry TPM command/response buffers. But there is no evidence that the stock Windows ARM TPM driver understands such a transport. A device ID or PCI class alone cannot supply that support. Driver development, signing and pre-installation availability would be separate obstacles; no driver injection is proposed or performed.

### 3. Shared-memory platform interface plus guest firmware — research candidate

Potential design: map a custom device's shared region, make a firmware component discover it, and publish a standard TPM-facing interface to the OS. Host-side code would translate its requests to the command engine. This avoids assuming that Windows speaks a private Virtio TPM protocol.

Unknowns that prevent claiming feasibility:
- Can the selected TPM interface's register semantics, locality, status transitions, cancellation and ordering be faithfully implemented with shared memory and polling rather than trapped accesses? In particular, write-one-to-clear and register access semantics cannot simply be assumed to behave like RAM.
- Will firmware and the Windows ARM inbox driver map and use such a region as required? Does polling have acceptable latency and CPU cost?
- How is the firmware component loaded reliably before the installer, without altering the owner's ISO? A separate developer-controlled firmware/test medium is a possible later design, not something created here.
- Can ACPI publication, TPM2 table start method, resource lifetime, TCG2 protocol and event log be made correct on this platform?
- Does using a custom Virtio device with this Windows configuration validate and remain stable? Apple's documentation scopes custom-device use to Linux; Windows behaviour is not established by the working Linux GPU experiment.

The existing private ROM-image design note is not a solution already in hand: its selector contract, image layout, firmware replacement and variable-store compatibility remain untested. Do not add it to production merely to make this sketch possible.

## Recommended decision and proof sequence

1. First isolate the current helper crash. A TPM is not a remedy for a host memory-protection fault before any observed Windows screen.
2. Keep TPM support marked absent in the product until evidence changes it. No Setup requirement is disabled, falsified or skipped by this investigation.
3. For a separately approved prototype, validate the command engine and persistent-state lifecycle outside the VM, then validate a bounded custom-device transport in a disposable Linux guest. This tests plumbing only.
4. Before a Windows boot experiment, review a concrete firmware/discovery design and prove its required register semantics. Stop if the public API cannot implement them; do not silently expand private-API scope.
5. Acceptance would require an unmodified Windows ARM guest to bind its standard TPM driver and report TPM 2.0 ready, plus successful reboot/persistence, firmware/measurement checks, failure handling and recovery tests. Setup acceptance alone is insufficient.
6. Only after that proof: architecture decision, licensing review, threat model, snapshot/clone/backup policy, UI/help and implementation plan.

This investigation implements a real TPM only if its protocol and integration can be made correct. It does not propose spoofing a TPM presence flag or changing Windows Setup checks.
