---
status: accepted
date: 2026-10-25
---
# 0058 — The virtio GPU's pure core is a library target of the root package, and its adapters live in the app

## Context

The feasibility study of roadmap 0014 (ADR-0014, item 3) built a host-implemented virtio GPU in a package of its own,
`Packages/VirtioGPU`: a pure library (the wire format, the resource store, the device state, a bounded command record), a
command-line parser, and a runner that boots one Linux guest with the device. The first real-guest run (roadmap 0014,
2026-10-25) answered the study's question: a stock Debian 13 arm64 guest bound its `virtio_gpu` driver, carried 2197 transfer
and flush pairs without an error, and was notified by giving an element back and by a configuration update. The next step is the app: a Linux
machine whose display is this device, shown in the machine's window. The app must then link the pure core, and the runner
stays what it is, a measurement tool with a thin Virtualization adapter of its own.

A nested package that the root depends on does not work here. A path dependency from a nested package on the root names the
root package by the directory it was checked out in: in a checkout whose directory is not called `VMRunner`, SwiftPM refuses
it (`unknown package 'VMRunner'`, with the directory's name as the only valid package). Every worktree an agent uses is such
a checkout. The other direction is also costly: the core has about 160 `public` lines today, because the runner reaches it
across the package boundary, and a package the app links would keep them `public`, against ADR-0047 (nothing here is linked by
anyone outside this repository).

## Decision

1. **Root targets only.** The nested package is removed. The root package gains `VirtioGPU` (the pure library: every file of
   the former core except the command-line parser), `VirtioGPUTests`, `VirtioGPURunnerCore` (the runner's command-line
   parser alone, ADR-0042 item 3), `VirtioGPURunnerTests`, and the executable `VirtioGPURunner`, which links `VirtioGPU` and
   `VirtioGPURunnerCore`. The runner's Virtualization half stays in the executable.
2. **`package` access, never `public`, as ADR-0047.** A declaration is `package` when another target of this package uses it,
   internal otherwise, and the library's tests use `@testable import`. A declaration only the library's own tests read carries
   the trailing `// @dw:accept:this referenced-only-by-tests -- <reason>` where the dead-code gate asks for it.
3. **The core imports nothing.** `VirtioGPU` imports no framework at all (not Foundation, not Virtualization, not AppKit), so
   its tests run anywhere and the device's decisions are the same in every host. Guest memory reaches it through a protocol it
   defines; the adapters implement it.
4. **The adapters stay in the targets that own the framework.** The app links `VirtioGPU` and holds its own Virtualization
   adapter in `Sources/VMRunner/Engine` (ADR-0047 item 5): the delegate callbacks, the guest memory mapping, the device
   configuration, the frames it hands to the machine's window. The runner keeps a thin adapter of its own. Both need macOS 27
   and sit behind `@available(macOS 27.0, *)`. The two adapters are separate on purpose (the runner is the measuring
   instrument, the app is the product); the logic they would otherwise copy is not.
5. **Queue serving is shared.** What decides whether a queue element is served correctly is in the library, not in either
   adapter: read the request once, refuse one longer than the device reads after its header, hand the copy to the device
   state, write the answer only when it fits, give the element back exactly once on every path. The library defines a
   protocol over a queue element and a function that serves one; each adapter conforms its framework element to the protocol,
   and the library's tests prove the rules with a fake element.
6. **The runner is not part of the app.** `vmr build-app` builds the `VMRunner` product only, so the runner is neither
   compiled for nor bundled in the app. The gate builds and tests everything.
7. **A second pure library may join.** A virtio input device (keyboard and pointer for a machine with this GPU) would be a
   second library target, `VirtioInput`, under the same rules: pure, importing nothing, `package` access, its adapter in the
   app. It is not decided or started here. (Update 2026-10-25: the library exists as `Sources/VirtioInput`, under these rules,
   and no target links it yet.)
8. **The layering is checked.** Tests read the manifest and the sources: the library depends on no target, no package and
   imports no framework; the command-line parser imports no user-interface or virtualization framework; the app does not link
   the runner or its parser; the manifest's remaining nested package (the container runner) is still unknown to the root
   package.

## Consequences

The root package gains five targets and loses one nested package, so `Packages/VirtioGPU` and its entries in `.vmr.json` and
`.swiftlint.yml` go; the gate's build, tests, format, lint and analyzers cover the targets as they cover the other
library targets, and the dead-code, clone and leak analyzers see the library and the runner as part of the root. The rule that
a nested package copies the shared settings block now applies to the container runner alone. The tests that kept the study
out of the root manifest are rewritten for the new layering, which is a deliberate change of tests. This amends the note
ADR-0014 carries about a package of its own, and ADR-0047's list of library targets the app links grows by one when the
app adopts the device.

An alternative stays open for the owner: keep the nested package and depend on the root with `.package(path: "../..")`. It
works only in a checkout named `VMRunner`, and it keeps the surface `public`.

## What this does not decide

Whether the app turns the device on by default or per machine, how the scanout reaches the machine's window, resizing the
display from the window, the pointer and the keyboard, or 3D; each is a roadmap 0014 item of its own. Whether `VirtioGPU`
becomes a package of its own is decided with ADR-0047's condition: when a consumer outside this repository exists.
