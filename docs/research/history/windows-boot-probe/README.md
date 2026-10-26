# Windows boot diagnostic sources — 2026-10-26

Supporting material for the [boot-display investigation](../../windows-boot-display-2026-10.md), **not app code or a supported boot solution**. The `.txt` suffix keeps historical probe sources out of compilation and commit hooks. No binary firmware or downloaded headers are committed.

- `SelectorProbe.swift.txt`: checks the fine-grained trap selector's type encoding, Boolean read-back and restoration. Creates no VM.
- `BootProbe.swift.txt`: the disposable signed diagnostic runner; the source has explicit historical scratch/ISO paths. It is not portable as-is and must never be pointed at a user's existing machine. Uses both private switches outside the production module only for this isolated experiment.
- `FramebufferBoot.c.txt`: the **tested** standalone UEFI application. It publishes a bounded RAM-backed GOP, chainloads an EFI file from another volume, records diagnostic stages and remains resident if the child returns. No installer checks, Setup scripts or simulated keyboard input.
- `FramebufferBoot-retry.c.txt`: a **compiled but not run** follow-up that retries the media boot after EFI_TIMEOUT, without generating input. It needs an owner-observed run; it is not verified by the earlier single-attempt results.
- `makeboot.py.txt`: creates the disposable raw GPT/FAT16 EFI System Partition containing the supplied EFI binary. A host read-only mount and byte comparison verified the disk layout and file contents.
- `backstop.sh.txt`: the independent 240-second recorded-pid backstop used by the experiment. The runner's nominal 180-second loop actually stopped the longer runs after about 188–190 seconds; do not mistake it for an exact 180-second wall-clock limit.
- `*.log.txt`: host-runner logs for six sub-runs. No owner observation of guest pixels is asserted by these logs.
- `stages.json`: only the diagnostic variables and directory names extracted from the scratch EFI stores, not the stores themselves. Repeated stages preserve writes found in the variable journal, not necessarily distinct current variables.

## Header provenance and rebuild

The UEFI type definitions came from EDK II commit `d46aa46c8361194521391aa581593e556c707c6e` (the `edk2-stable202508` tag), under `MdePkg/Include`. They carry BSD-2-Clause-Patent notices. The [header checksums](headers.sha256) record all 30 downloaded files; fetch those exact files and preserve their upstream notices if redistributing them. No code from the separately studied FSL-licensed implementation was copied into this diagnostic; only the publicly discoverable selector names and the described compatibility requirement informed the probe.

The tested EFI image was built with the following flags (replace paths only after reviewing the sources):

```text
clang -x c -target aarch64-unknown-windows -ffreestanding -fshort-wchar -fno-builtin \
  -fno-stack-protector -mno-implicit-float -O2 -Wall -Wextra -Werror \
  -I HEADERS -I HEADERS/AArch64 -c FramebufferBoot.c.txt -o framebuffer.obj
lld-link /nologo /Brepro /nodefaultlib /dll /entry:efi_main \
  /subsystem:efi_application /out:BOOTAA64.EFI framebuffer.obj
```

After restoring the exact tested single-attempt source, a rebuild produced the **same** SHA-256 as the 9216-byte image recovered from the tested FAT disk: `7fef045bcc3d0b3ec72353ee5c95f3684b824986e96af854dfda86e484c90d7e`. See [tested-efi.sha256](tested-efi.sha256). This verifies build reproducibility in this environment, not UEFI or Windows compatibility in general.

These sources are deliberately not wired into `vmr`, the app bundle or the gate. They have not received the unit tests, memory-safety review, resource lifecycle design, firmware licensing/distribution review, decision record and observed Windows boot that production integration would require. The default app guard remains intact.
