# Owned Windows framebuffer bootstrap

Independent UEFI implementation for [ADR-0060](../../docs/adr/0060-windows-boot-uses-a-bounded-framebuffer-and-a-paired-capability.md). It does not contain Windows or the separately studied FSL implementation. It never edits installer files, changes Setup checks, or generates input.

`FramebufferBoot.c` is compiled into an ARM64 EFI application. A generated Swift source embeds its bytes and SHA-256 in the signed app; there is no runtime compiler, linker, download or external resource lookup. The app verifies those bytes before creating its own read-only boot medium.

## Rebuild, verify and test

```text
swift run vmr windows firmware --update    # after reviewing a C source change
swift run vmr windows firmware             # deterministic byte comparison against the embedded artifact
swift run vmr check                        # includes native ASan/UBSan C regression harness, no guest
```

Rebuilding requires Xcode clang and `lld-link` on PATH. The original environment uses Swift's lld-link. `/Brepro` makes output deterministic for the same toolchain/source/headers. A changed toolchain may legitimately change output and requires reviewed regeneration. App builds consume the checked-in Swift bytes and do not require lld-link. The CLI verifies all header hashes before compiling. Tests also compare the C source hash with the embedded source fingerprint and the embedded bytes with their digest and ARM64 EFI header.

`Tests.c` runs natively, without EFI, virtualization, screens or guest input. It covers fills, read/write blits, horizontal/vertical overlap, invalid operations, dimensions, strides and overflow, plus forwarding cessation at ExitBootServices. This is targeted regression coverage, not a proof of complete firmware correctness or installed Windows compatibility.

## Provenance and licence

`Include/` contains the 30 exact EDK II headers from commit `d46aa46c8361194521391aa581593e556c707c6e`, `MdePkg/Include`. `headers.sha256` records their individual hashes, matching the original diagnostic research pin. Their BSD-2-Clause-Patent notices are preserved; upstream's full `License.txt` at that revision is included. Fetch origin: `https://github.com/tianocore/edk2/tree/d46aa46c8361194521391aa581593e556c707c6e/MdePkg/Include`. No upstream implementation library is linked.

The C source derives from this repository's independently authored diagnostic, not third-party platform code. It intentionally stays resident on every outcome, publishes a bounded coherent record tied to the host-created boot token and increments its boot generation. A fresh separate EFI variable store forces the bootstrap on cold starts; an owned boot option/BootNext routes normal guest reboots through it. Installed-system acceptance, including Windows rewriting firmware variables, is not established by the native tests. The original guest EFI store is never overwritten.
