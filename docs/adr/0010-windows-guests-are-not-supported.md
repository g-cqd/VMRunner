---
status: superseded
date: 2026-10-21
superseded-by: ADR-0059
---
# 0010 — Windows guests are not supported

> **Superseded by ADR-0059** ([Windows on ARM is supported, with its one private interface behind a fail-closed module](0059-windows-on-arm-is-supported-with-its-one-private-interface-behind-a-fail-closed-module.md)).
> Windows on ARM is now supported as experimental, behind a private capability that fails closed. The text below is kept as it was.

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
