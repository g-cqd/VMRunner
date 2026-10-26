# GPU-accelerated Linux and Windows guests: assessment (2026-10-24)

Written by a read-only researcher agent; saved by the orchestrator in condensed form. Host macOS 27.0.1, SDK 27.0. [V] verified by
the agent (local file, header, fetched page); [S] secondary or single-author source; [I] inference. Nothing was built or run.

## Verdicts

- **Windows acceleration:** no GPU-accelerated Windows guest can be delivered on Virtualization.framework today. Apple offers no
  vTPM or GPU path for it, no signed ARM64 3D WDDM driver exists, and a custom virtio device is documented as Linux-only.
- **Linux:** a host-implemented virtio-gpu is feasible on macOS 27; Apple adds no GPU device.

## Windows 11 ARM under Virtualization.framework

- No public support [V]: no Windows or TPM mention in the 27.0 headers; ADR-0010 records "not supported".
- One unmerged fork of a third-party tool boots it with a private PMU selector and a homemade UEFI framebuffer shim (a ~7 KB driver
  copying changed rows every 40 ms), skipping Setup to avoid the missing TPM; devices need virtio-win ARM64 drivers (`viostor`,
  `NetKVM`, `viogpudo`, `viorng`, `viofs`) injected offline [S]. No suspend, no sound, display-only driver, private API may vanish.
- What the app would have to provide: the private selector (fail closed), a GOP framebuffer shim, install-media authoring (WinPE,
  DISM, answer file), pinned virtio-win drivers (BSD-3-Clause source; attestation-signed binaries). No vTPM, so outside Microsoft's
  stated requirements. NVMe (inbox Windows driver) might avoid the storage driver at install time: unconfirmed on VZ.
- Microsoft lists Parallels as the authorised Mac route for Windows 11 on Apple silicon; a licence per instance is required [V].

## GPU for Windows

- `viogpudo` is 2D only. 3D WDDM drivers (`viogpu3d` PR in the virtio-win driver repo, Yttrium, vmlab-win3d, Triton) are alpha,
  test-signed, x64/QEMU/Linux-host oriented; none targets ARM64 plus a macOS host [S].
- A custom virtio device would still need the QEMU-side 3D protocol (blob, Venus capset) and is documented for Linux only: not viable [I].
- Accelerated Windows on Apple silicon today: Parallels (DirectX 11, OpenGL 4.3) and VMware Fusion (DirectX 11); both closed and not
  embeddable [S].

## GPU for Linux

- Realistic stack [S]: guest `virtio_gpu` + Mesa (virgl for GL, Venus for Vulkan); our `VZCustomVirtioDevice` (ID 16, PCI class 3);
  virglrenderer in-process; GL through ANGLE on Metal (plus libepoxy); Vulkan through Venus with KosmicKrisp (Mesa, Vulkan 1.4
  conformant, Metal 4) or MoltenVK (deprecated by Khronos).
- Proofs of concept, both young single-author MIT projects, not reproduced by us: vzgpu (Venus; Fedora 45 Beta, kernel 7.2.x with a
  blob round-up patch, Mesa 26.2.4+; tested on macOS 27.2 with an M5; open defects: tearing, a VMM abort on context destroy, hvc0
  input loss) and EZVM (virgl + ANGLE + Metal, falls back to Apple's device; no machine-state save/restore for the custom path).
- Page size: VZ maps at 16 KiB, blob sizes must be multiples of that; the workaround is a patched guest `virtio_gpu`; Rosetta needs a
  4 KiB-page guest kernel. A stock distro kernel with stock Mesa may not work yet [I].
- Interrupts [V]: no interrupt-raising method in `VZVirtio*.h` / `VZCustom*.h`. Host-to-guest primitives found: `returnToQueue`,
  `requestDeviceReset`, `updateDeviceSpecificConfiguration:`. The spike must test whether they suffice.
- Licences (constraints only): vzgpu, EZVM MIT; MoltenVK Apache-2.0; virglrenderer, ANGLE, libepoxy MIT/BSD-3/MIT from memory [I],
  unverified; Windows-driver and QEMU stacks bring LGPL/GPL/MPL pieces. Any bundled library must be signed and carry notices.

## Effort ranking (inference)

| Rank | Item | Feasibility | Effort |
|---|---|---|---|
| 1 | Linux 2D virtio-gpu scanout | High | 1 to 3 weeks with integration |
| 2 | Linux virgl GL | Medium | several weeks to a few months |
| 3 | Linux Venus Vulkan | Medium-low | months |
| 4 | Windows 2D display (private API) | Low-medium, non-public | weeks plus ongoing breakage risk; not App Store eligible |
| 5 | Windows accelerated | Blocked | not estimable |

Common to rows 1 to 3: a display view that is not `VZVirtualMachineView` (a custom device is not a `VZGraphicsDevice` [I]), input
forwarding, resize via config-space update, save/restore refusal (a custom device must implement the save/restore delegate methods
or the configuration raises; renderer state cannot be rebuilt from `NSData`), `#available(macOS 27.0, *)` guards.

## Recommendation

1. Spike A (3 to 5 days): the Linux 2D custom device; its first question is whether used-ring return and config-change updates
   reach the guest without an interrupt API. Stop at a decision.
2. If A passes, an integration card (toggle, fallback to Apple's device, resize, input, save/restore refusal); it has value without 3D.
3. Spike B (1 to 2 weeks): link virglrenderer + ANGLE into a shared library target, minimal virgl context, measure a `glxgears`-class
   guest app against llvmpipe; decide bundling.
4. Venus only after B and the owner accepting the patched guest kernel and Mesa requirement.
5. Windows 2D: keep ADR-0010; if wanted, an off-by-default experiment behind a private-selector check. Windows acceleration is
   documented as unavailable; re-check upstream `viogpu3d` and Apple release notes at each major macOS release.

## Owner decisions

1. Is 3D for Linux worth a macOS-27-only feature with a patched guest kernel, given the `.macOS(.v26)` floor?
2. Accept bundling virglrenderer, ANGLE, libepoxy and a Vulkan ICD, or stop at 2D?
3. Is a private-API Windows 2D experiment acceptable at all (ADR-0010 says no)?
4. Save/restore policy for the custom device: refuse, or snapshots only on a stopped VM?
5. Keep a helper-process route (a separate VMM for Vulkan and GL) on the table as a parallel option?
6. Who tracks the upstream signals: Apple's interrupt API, Mesa blob rounding, virtio-win `viogpu3d`?

## Not verified

virglrenderer, ANGLE and libepoxy licences; KosmicKrisp's in-tree licence; upstream Venus status on macOS; the fork's source beyond
its write-up; any runtime behaviour of custom devices; whether Windows accepts NVMe on VZ; clipboard without `VZVirtualMachineView`;
whether Parallels supports DirectX 12 (sources conflict).
