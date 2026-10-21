---
status: accepted
date: 2026-10-21
---
# 0011 — Strict memory safety everywhere but test support

## Context

Untrusted input reaches parsers, and the app handles raw descriptors and memory.

## Decision

1. Strict memory safety and warnings-as-errors are on for the app, the tooling and their tests, with the upcoming
   language features enabled. Each `unsafe` carries its justification.
2. Test support builds without strict memory safety because it parks raw `UnsafeContinuation`s by design; it keeps every
   other flag.
3. `unsafe` is not added for a speed gain that was not measured. Hashing with a reused `read(2)` buffer measured about
   2.4 GB/s against 2.0 GB/s for `FileHandle` at 4 MiB, which does not justify it.

## Consequences

A new use of an unsafe API fails the build until it is marked and justified.

## What this does not decide

Moving to arm64e (pointer authentication), which is an opt-in build option.
