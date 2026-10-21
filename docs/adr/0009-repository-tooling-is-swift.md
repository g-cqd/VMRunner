---
status: accepted
date: 2026-10-21
---
# 0009 — Repository tooling is swift

## Context

The gate, the analyzer installer, the app bundler and the git hook were shell and Python scripts: hard to test, different
locally and in CI.

## Decision

1. All of it is Swift: a `DevTools` library, a `vmr` command line, and three command plugins that forward to it.
2. CI runs the same `vmr check` steps as a local run.
3. 50 end-to-end tests run the real binary against fixtures, a fake analyzer release and temporary git repositories.
4. Analyzer archives are verified against a SHA-256 in the lock file before anything is unpacked or run; a tampered
   archive is refused.

## Consequences

SwiftPM's plugin sandbox cannot run the whole gate (a nested build cannot apply its own sandbox and can deadlock on the
outer lock), so `swift run vmr` is the primary path and the plugins are a convenience. Two gates must not share one build
directory; a second invocation waits on the first.

## What this does not decide

A lock that makes the second invocation fail fast with a clear message.
