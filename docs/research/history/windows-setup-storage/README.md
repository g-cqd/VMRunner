# Windows Setup/display/storage diagnostics — 2026-10-26

Historical evidence for the [Setup/storage study](../../windows-setup-storage-2026-10.md), **not app code or a supported boot solution**. All source snapshots have `.txt` suffixes. No screenshots, firmware images, disks, EFI stores, downloaded headers or third-party driver binaries are committed.

## Runs

Directory suffixes identify the historical scratch run, not a portable invocation:

- `1026131254`: first owner-observation attempt after the original timeout probes.
- `1026131942`: owner-observed Windows logo.
- `1026132606`: live host framebuffer mirror; owner reported installation starting, poor responsiveness and no target drive with NVMe.
- `1026134146`: first bounded Virtio block / ARM64 viostor diagnostic; includes full driver-ISO verification metadata, extracted/package file hashes and catalog certificate inspection.
- `1026141326`: final 15-minute run, target 15 Hz host mirror, bounded verified driver-file range fetch; owner screenshots show the started `1AF4:1042` controller and online 64 GB target. `owner-confirmed-storage.txt` transcribes those observations and limits.

## Contents and replay limits

`BootProbe.swift.txt` is each disposable signed runner. `LiveFrameView.swift.txt`, where present, is its in-memory display overlay and bounded guest RAM reader. `FramebufferBoot.c.txt` is the corresponding EFI bootstrap. `makeboot.py.txt` builds only disposable GPT/FAT boot media. The `fetch-*.py.txt` files fetch/build experimental driver media; their network/file handling is not production tooling. `supervise.py.txt` enforces a second wall-clock cap and removes scratch artifacts. JSON, hashes, stat records and logs preserve provenance, diagnostic checkpoints, unchanged-media checks and cleanup outcomes, not full firmware variable stores.

These snapshots contain historical absolute paths and require reviewed path substitution; never point them at an existing user VM or writable installer. Each run requires explicit owner authorisation, bounded resources/runtime, fresh disposable storage, read-only media and cleanup. They are not wired into `vmr` or the app, and bypass no Windows Setup requirement. No automatic input or screenshots are implemented. Source snapshots may name already-deleted scratch paths.

The [original archive](../windows-boot-probe/README.md) documents pinned EDK II headers, their checksums and clang/lld build flags. The later bootstrap sources here differ from the original tested single-attempt artifact; **do not attribute its checksum to these later sources**. No production tests or independent source-to-binary reproducibility check are claimed for these follow-ups. Review metadata parsing, memory bounds, image creation, callbacks, reboot/shutdown and licensing before any production adoption.

The original FSL-licensed implementation was not copied. Standard BSD-licensed UEFI header provenance remains as recorded in the original archive. A driver catalog certificate listing is not equivalent to a Windows trust or signature-verification result. The archived early `setup_verification` fields describe the state at their capture time; the later owner PCI/DiskPart observation supersedes the blanket claim that storage never enumerated, not every earlier uncertainty.
