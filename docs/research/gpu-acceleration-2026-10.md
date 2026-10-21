---
date: 2026-10-21
question: "Can guests get 3D acceleration, and which?"
feeds: [roadmap 0014, ADR-0014]
---
# GPU acceleration for macOS, Linux, and Windows guests

**Status: investigated.** What can be promised today, and what it would take to go further.

| Guest | Under Virtualization.framework (VZ) today |
|---|---|
| macOS | **Metal-accelerated**, one display, nothing to configure. OpenGL is software-only. |
| Linux | **No 3D.** The virtio-gpu device is a 2D scanout; Mesa falls back to software rendering (llvmpipe). |
| Windows 11 ARM | Not supported by Apple; third-party previews boot it **without** GPU acceleration. |

## macOS guests

`VZMacGraphicsDeviceConfiguration` takes only a size and a pixel density; there are no GPU parameters. The headers say
"Maximum of one display is supported", and a two-display configuration fails validation
([Apple forums](https://developer.apple.com/forums/thread/761810)). The guest drivers ship with the host
(`AppleParavirtGPU.kext`). Apple documents the result: Metal features such as argument buffers and indirect command
buffers work in a guest ([WWDC26 session 224](https://developer.apple.com/videos/play/wwdc2026/224/),
[WWDC22](https://developer.apple.com/videos/play/wwdc2022/10002/)). Secondary reports: a stock 26.5 guest reports an
older GPU family with 32 KB threadgroup memory and no SIMD-group matrix, which makes some compute workloads pick slow
paths ([Cua](https://github.com/trycua/cua/blob/main/blog/gpu-passthrough-macos-vms.md)); an old Geekbench Metal run
scored about 92% of host ([Eclectic Light](https://eclecticlight.co/2026/04/29/virtualisation-on-apple-silicon-macs-is-different/)).
Hardware video decode in a guest has not been shown without private APIs.

## Linux guests

`VZVirtioGraphicsDeviceConfiguration` has only `scanouts` ("Maximum of one scanout is supported"). Grepping every
Virtualization header for virgl, Venus, gfxstream, capset, blob, OpenGL, Vulkan, 3D, and "accelerat" finds nothing.
A guest's `dmesg` shows `-virgl -resource_blob -host_visible`
([example](https://github.com/XueshiQiao/omarchy-vm)); UTM's maintainer and Lima both say the same.

### Alternatives that do give Linux 3D (all bypass VZ)

| Option | Hypervisor API | Accelerates | Notes |
|---|---|---|---|
| QEMU + virglrenderer | Hypervisor.framework | OpenGL (ANGLE on Metal); Venus Vulkan needs patched forks | Helper process only; not upstream for Venus on macOS. |
| UTM | QEMU (HVF) and VZ | OpenGL 4.1, experimental Vulkan 1.3 | Betas; the VZ backend gets no GPU. |
| libkrun / krunkit | Hypervisor.framework | Venus via virglrenderer, MoltenVK, Metal | Apache-2.0; API unstable ("libkrun 2.0"); Red Hat measured llama.cpp at 74–80% of native. |
| Apple Containerization | VZ | none | Maintainers: "we do not currently support this." |
| Parallels / VMware Fusion | Hypervisor.framework | Linux GL 3.3 / Windows DX 11 | Closed, paid, not embeddable. |

Switching to any of these means a different hypervisor stack, so VZ features (Rosetta, saved state, Secure Boot
enrollment) are lost.

## An option specific to macOS 27: a custom virtio-gpu

The macOS 27 headers add `VZCustomVirtioDeviceConfiguration` (device ID, PCI class, queue count, feature bits,
device-specific config, shared-memory regions), queue access (`VZVirtioQueue`, `VZVirtioQueueElement`), guest-memory
mapping, and shared-memory mapping. Those are the right primitives for a virtio-gpu 3D backend, and two young projects
claim proofs of concept: [vzgpu](https://github.com/Quiet-Wolfe/vzgpu) (Venus on macOS 27.2) and
[EZVM](https://github.com/everettjf/ezvm) (virgl through ANGLE and Metal). Gaps found in the headers:

- no documented way to raise a guest interrupt, and no callback for guest writes to device config;
- VZ maps host memory at 16 KiB granularity, so blob alignment needs guest kernel help;
- the device is not a `VZGraphicsDevice`: no `VZVirtualMachineView`, you present scanouts yourself;
- saved state cannot reconstruct renderer contexts; it runs in the app process, so renderer code shares the app's trust;
- macOS 27 hosts only, Linux scope in the docs, and nothing reproduced independently.

Effort estimate (not documented): a minimal 2D device is days to weeks; virgl GL weeks to months; Venus months, plus a
distribution pipeline for virglrenderer, ANGLE, libepoxy, and KosmicKrisp.

## Recommendation

- **Promise:** macOS guests get Metal; Linux guests get 2D with dynamic resize.
- **Investigate:** a macOS 27 custom virtio-gpu spike (2D first, then virgl, then Venus, with a fallback to Apple's
  device); and a separate krunkit/QEMU helper backend for users who need Vulkan or GL.
- **Document as unavailable:** 3D for Linux on macOS 26 and earlier (and on 27 until a device is shipped), any GPU
  acceleration for Windows, multiple displays, and OpenGL on the GPU in macOS guests.

Not verified: a macOS 27 guest's Metal family; upstream status of Venus on macOS in virglrenderer; the licences of QEMU,
krunkit, virglrenderer, ANGLE, and libepoxy; all performance numbers beyond the cited sources.
