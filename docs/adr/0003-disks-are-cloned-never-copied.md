---
status: accepted
date: 2026-10-21
---
# 0003 — Disks are cloned never copied

## Context

Machine disks are tens of gigabytes. Duplicating, snapshotting and running throw-away copies by copying bytes is slow and
doubles the space.

## Decision

1. Every operation that copies a disk or a bundle uses `clonefile(2)`: duplicate, snapshots, disposable machines.
2. Disks are sparse raw images; only blocks the guest writes use space.
3. A duplicate is built under a temporary name and renamed into place once its identity is written, so a crash never
   leaves two machines sharing an identifier.
4. The macOS restore image is deleted after a successful install; a saved memory state is deleted once restored.
5. Disk usage reports blocks shared with clones in full, so the true cost is lower than the number shown.

## Consequences

Cloning needs the library and its copies on one APFS volume, which the default location satisfies. Raw sparse images
clone well but do not shrink when the guest deletes files; whether ASIF improves that was not verified.

## What this does not decide

Switching to ASIF images.
