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

## What happened (2026-10-22)

The cheaper first stage was done for the policy and the stack: `NetPolicy` and `NetStack` are library targets of the root
package, linked by the app, the headless helper and the tests (ADR-0047). The study's numbers, now measured:

- **`package` declarations.** 127 declarations needed `package` (78 in `NetPolicy`, 49 in `NetStack`) and four imports
  became `package import` (`Foundation` in the policy where a signature exposes `TimeInterval`, `NetPolicy` twice and
  `Foundation` once in the stack). The study estimated 600 to 900 `public` declarations across three extractions; two of
  the three needed about a fifth of the low figure, because the app drives the stack through one class (`UserNetStack`) and
  its tests use `@testable import`. The compiler forces some of the keywords: an enum case follows its enum, a
  conformance member must be as visible as its type, and a synthesized or default initializer is internal even in a
  `package` type, so four types (`InterfaceSnapshot`, `UserNetConfig`, `SystemNameResolver`, `SilentUserNetLogger`) got an
  initializer written out.
- **One reference to an app type.** The policy named `EditorLimits.maxRuleLength`; the limit moved to
  `NetworkPolicy.maxRuleLength` and the editor limit now reads it.
- **Per-packet cost.** `swift run vmr check bench` after the move: the allocation figures are exact (the policy decisions
  19, 4, 20, 5, 4, 24, 6; every stack path 0), the policy decision's retired instructions are 56,500 against 56,328 (+0.3%,
  budget 3%), and the checksum digests are unchanged (+0.0% and +0.1%). The stack's per-packet instructions are not a
  benchmark figure (only its allocations are), so the cost of the module boundary there is shown by the allocation counts
  and by the structure: the generic core and its flows are internal, the app calls `UserNetStack` only, and the stack calls
  into the policy once per new flow (`PolicyGate.judge`, which allocates by design), never per packet. No `@inlinable` was needed or added. The gate's sanitizer runs (address, thread, undefined
  behaviour) pass as before.
- **Analyzer baselines.** They do not need regenerating: after the moves arcleak and deadwood report no finding and dolly
  reports no exact clone, with the baselines as they were. The deadwood baseline holds 22 fingerprints that accept nothing
  (the analyzer reports no finding without the baseline either, on the tree before the moves and after); it was left alone.
- **Still not verified.** Build times, and whether a root plugin may depend on another package's executable. Whether the root
  `swift test` skips the dependencies' tests no longer matters while the targets share the root package.
