---
status: accepted
date: 2026-10-21
---
# 0001 — The app links system frameworks only and tooling pins its packages

## Context

An app that runs untrusted guests should have a small, auditable supply chain. At the same time the repository's tooling
(process spawning, a command line with subcommands, debounced writes, a heap for the test clock) is code nobody should
write again when Apple and the Swift project already ship it.

## Decision

1. The `VMRunner` app target links Apple's system frameworks and one package, `swift-async-algorithms`, for `debounce`.
2. Developer tooling (`DevTools`, `vmr`) links `swift-subprocess` and `swift-argument-parser`. Test support links
   `swift-collections` (`HeapModule`). Neither is linked by the shipped app.
3. Every package is pinned with an exact version and `Package.resolved` is committed; Dependabot proposes upgrades one
   at a time.
4. Packages that duplicate the SDK are not added: `swift-crypto` (CryptoKit hashes incrementally), `swift-system` (the SDK
   module), `swift-atomics` (`Synchronization`), `swift-log` (`os.Logger`). `swift-nio` and `swift-markdown` were weighed
   and rejected for C-target weight and for not fitting the problem.

## Consequences

The app's package graph is two packages (async-algorithms and its dependency, collections). A new dependency is an
architectural decision that needs an ADR.

## What this does not decide

Whether `swift-configuration` is worth its six-package graph if layered configuration grows beyond a defaults-plus-plist
merge.
