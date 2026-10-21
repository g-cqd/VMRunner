---
status: accepted
date: 2026-10-21
---
# 0020 — SwiftLint is a pinned, checksum-verified release

## Context

The three analyzers are pinned releases: version, commit and SHA-256 in `Scripts/analyzers.lock`, checked before anything
from the archive runs. SwiftLint was the one gate tool still taken from `PATH`, which [ADR-0018](0018-ci-is-a-lane-matrix-that-runs-vmr-and-skips-what-did-not-change.md)
left open. Its version therefore differed between machines and CI, and a new release could fail a green gate with no change in
the repository.

## Decision

1. SwiftLint is installed exactly like the analyzers: `SWIFTLINT_VERSION`, `SWIFTLINT_COMMIT` and
   `SWIFTLINT_SHA256_MACOS_ARM64` in the lock, into `.tools/swiftlint-<version>/`. The checksum is verified before the
   archive is listed or unpacked, and the unpacked binary must report the pinned version before it is kept; a tampered
   archive is refused and never executed.
2. The installer takes a release spec (owner, repository, tag prefix, archive kind) instead of an analyzer name. The
   archive is the portable release, a zip with the binary at its root; macOS's `tar` lists and unpacks it, so no new tool
   is involved. The pinned binary is a universal one, used on Apple silicon like the rest.
3. Every use resolves it through one function, `ToolLocator.swiftlint`: the `swiftlint` gate step, the pre-commit hook and
   the end-to-end tests. `PATH` is never searched. `SWIFTLINT_BIN` replaces the pin with a binary of the caller's own,
   unchecked, as `ARCLEAK_BIN`, `DOLLY_BIN` and `DEADWOOD_BIN` do.
4. CI and the contributing guide install nothing: the first step that needs SwiftLint downloads it.
5. The pinned version is the one the project already used (0.65.1), so adopting the pin changes no finding.

## Consequences

A version bump is a reviewed change to the lock, with the violations the new version reports fixed in the same change.
The first lint on a fresh checkout needs the network (one download of about 12 MB); an offline machine sets
`SWIFTLINT_BIN`. The end-to-end tests give their fixture packages the checkout's pinned SwiftLint through `SWIFTLINT_BIN`,
because a fixture has no lock of its own.

## What this does not decide

Pinning swift-format (it ships with the Xcode toolchain), pinning the tools
for other platforms (the gate runs on Apple silicon only), and a way to list or update the pins automatically.
