---
date: 2026-10-22
question: "How should the repository be split into local Swift packages that separate concerns cleanly?"
feeds: [roadmap 0032, ADR-0001, ADR-0009, ADR-0011]
---
# Modularization into local Swift packages

Study, not a decision record. Sizes come from the tree at the time (the app target is ~14.5k lines: Network 5.3k, Model 3.1k
(+1.1k since), Engine 2.8k, Views 1.6k, Help 1k, ViewModels 0.6k). Build-time and performance effects are reasoned, not
measured.

## Short answer

- Three cuts are clean today: the policy engine, the user-mode network stack, and the checksum, signature and download code.
  Everything else is tangled through the library, configuration and controller types.
- Use few packages and several targets: a package is a review and release unit; compiler-enforced layering and build
  parallelism come from targets. Across packages `package` access is not enough, so the boundary API must be `public`.
- Recommended packages: test support, networking (policy and stack targets), image trust (signatures, checksums, catalogs),
  the container runner, optionally the tooling.

## Current graph (exceptions to the intended layering)

- The stack depends on the policy types only (11 files) and on the logger in two places; it never touches the configuration,
  the library or the engine.
- Upward edges from the model: the flow log and configuration use stack types; the library owns controllers and models and the
  provisioner calls back into it. Three type-level cycles: library and controller, library and provisioner, library and
  machine model.
- The VPN logic is spread over four places. The library imports SwiftUI and Virtualization. The downloads file mixes eight
  things (policy, redirects, checksums, downloader, image store, throttle, errors, a type named like Apple's framework).
- God types by referencing files: `NetworkPolicy` 24, `VMConfig` 17 plus views, `VMLibrary` 10, `MachineModel` 5,
  `ConfigurationBuilder` 5, `VMController` 4.

## Costs and benefits

- Per-packet speed: there is no `@inlinable` anywhere and the per-packet path stays inside the stack module, so no change is
  expected to the exact allocation baselines or the 3% instruction budget; `vmr check bench` after each extraction proves it.
  Never split the wire parsers from the stack core; do not enable library evolution.
- Settings: a manifest cannot import a shared Swift file; the same block between marker comments in every manifest, written
  and checked by `vmr`, is the recommended mechanism.
- Gate: tests, sanitizers, coverage, bench, analyzers, lint, the docs checker and CI cache keys loop over packages (~400 to 600
  lines of tooling). The dependency-policy test becomes "these manifests have no external dependencies".
- ADR-0001: the container runner's dependency would grow the root `Package.resolved` from 5 to about 30 pins; as its own
  package the root keeps 5. This is the strongest single argument.
- Rename hazards: never a module named `Network`, never a module named like its main type.

## Not to split

One-file packages; the wire format apart from the stack core; the configuration, library and controller types before they are
stable (cut the seams first, a `MachineStore` protocol); views and view models; the catalogs as their own package; module
per folder; the helper library until the helper hosts a real guest network; Help until it has a second consumer.

## Timing

Merge the network and downloads branches first (they touch the same files), then do the seams and the tooling, then the
extractions, before the new features. A cheaper first stage is the same targets inside the root manifest with `package` access.

## Not verified

Build times and benchmark effects; whether root `swift test` skips dependencies' tests (inferred from a forum thread); whether
a root plugin may depend on another package's executable; whether analyzer baselines key on paths; public-declaration counts
(estimated, 600 to 900 across the three extractions).
