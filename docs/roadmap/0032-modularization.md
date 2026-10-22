---
status: pending
blocked-by: ["0031"]
date: 2026-10-22
---
# 0032 — Separate concerns into local Swift packages, with one naming convention

Study: `docs/research/modularization-2026-10.md`. Packages live in `Packages/` of this repository and are consumed by the root
package through `.package(path:)`; they are not git submodules or separate repositories.

## Naming convention (to be recorded in an ADR when the first package lands)

- No planning word (spike, prototype, poc, experiment, draft, wip) in any identifier, directory, file, command or flag.
- No grab-bag suffix (`Kit`, `Util`, `Helper`, `Manager`). A library is named for the capability it provides.
- An executable's testable logic is `<Executable>Core`. A product name that states a real process role stays (`VMHelper`).
- Renames: done: `VMHelperKit` to `VMHelperCore`, `ContainerSpike` to `ContainerRunner`, `vmr sandbox-spike` to `vmr sandbox`,
  `vmr spike-sign` to `vmr container-sign`. Still to do, after the branches that import it have merged: `TestKit` to
  `TestSupport` and `CTestKitMalloc` to `CTestSupportMalloc`.
- A module is never named like Apple's frameworks (`Network`) or like its main type.

## Packages

| Package | Targets | Class |
|---|---|---|
| `TestSupport` | test support, allocation shim | tooling |
| `Networking` | `NetPolicy` (policy, rules, host and IP parsing), `NetStack` (the user-mode stack) | shareable |
| `ImageTrust` | `OpenPGP`, `ImageTrust` (checksums, download policy), `InstallerCatalogs` | shareable except the catalogs |
| `Containers` | `ContainerRunner`, `ContainerRunnerCore` | tooling |
| `Tooling` (optional) | `DevTools`, `vmr` | tooling |

Stays in the app: `VMConfig`, `VMLibrary`, `VMController`, `MachineModel`, `Provisioner`, Views, ViewModels, Help. Not split:
one-file packages, module-per-folder, the wire parsers from the stack core, anything that would freeze an unstable public API.

## Steps (the gate is green after each)

1. An ADR amending ADR-0001, ADR-0009 and ADR-0011 (packages, naming, shared settings block checked by `vmr`).
2. Seams inside the app with no moves: the VPN pieces next to their types, the policy gate with the policy, the virtualization
   glue out of the stack, `Downloads.swift` split into its parts, `Checksum` out of `VMConfig`, a `MachineStore` protocol,
   an injected logger in the stack.
3. `vmr` learns packages: the `packages` key in `.vmr.json`; build, test, sanitizers, coverage, bench, analyzers, lint and CI
   cache keys loop over them; a manifest-block sync and check replaces sharing settings between manifests.
4. Extract in order: `TestSupport`, `NetPolicy`, `NetStack`, `ImageTrust`. `vmr check bench` after each: the per-packet
   allocation baselines and the 3% instruction budget must not move.
5. Later and only on a second consumer: the configuration core, the configuration builder, `PrivateInterfaces`.

Timing: after the network and downloads branches merge (they touch the same files), before the new features.
