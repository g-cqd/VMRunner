---
status: accepted
date: 2026-10-21
---
# 0010 — Windows guests are not supported

## Context

Windows on ARM would be a natural guest.

## Decision

Not supported. Under Virtualization.framework a Windows ARM guest needs a private PMU selector and a custom UEFI
framebuffer; neither is public API, and neither can be shipped responsibly. The generic ISO option accepts any arm64 UEFI
installer and the help says plainly that Windows is not supported.

## Consequences

An experimental slice remains possible and is not recommended. See `docs/research/windows-on-arm-2026-10.md`.

## What this does not decide

Anything about a different virtualization backend.
