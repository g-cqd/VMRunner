---
status: accepted
date: 2026-10-22
---
# 0025 — config.json is untrusted and rejected at the boundary

## Context

A machine's `config.json` is read from a folder the user can copy, sync or receive. It decoded into plain `Int` fields that
later feed shifts and multiplications (`diskGiB << 30`, `maxRuntimeMinutes * 60`) and float-to-integer conversions
(`pixelsPerInch`, `pixelsPerPoint`), each of which traps on a hostile value, and the file was read and parsed whatever its
size or nesting. A crafted file could crash the app at launch, and the same machine would crash it again at every launch.

## Decision

1. The file is refused before it is parsed when it is larger than 1 MiB (it is read with a one-byte margin, not in full) or
   nests arrays and objects more than 32 levels deep (a single pass over the bytes). A real config is a few kilobytes
   and nests about six levels.
2. After decoding, every number the editor limits (`EditorLimits`) must be inside the limit, and every host path (shared
   folders, extra disks, the installer image) must be absolute. A value outside is a `DecodingError.dataCorrupted`; it is
   rejected, never clamped, because a clamped value would run a machine the user never configured. A machine whose
   config is rejected is skipped when the library loads and the reason is logged.
3. Each place that narrows or converts such a value still guards it (the disk image size, the runtime limit in seconds,
   the display size, the pixel density), so a value that reaches them some other way cannot trap.
4. A snapshot's recorded disk size is held to the same limit when snapshots are listed.

## Consequences

A hand-edited config with, say, a 5000 GiB disk no longer loads until it is corrected; the editor never offered such a value.
Adding a limit to `EditorLimits` does not by itself validate a new field: the field is added to `VMConfig.validate()`.

## What this does not decide

Bounds for the free-text and list fields (names, network rules), and the size of `snapshot.json`, which are not yet limited.
