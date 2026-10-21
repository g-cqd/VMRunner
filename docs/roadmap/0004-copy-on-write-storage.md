---
status: done
blocked-by: []
date: 2026-10-21
decision: ADR-0003
---
# 0004 — Clone instead of copy for duplicates, snapshots and disposable machines

`clonefile(2)` everywhere a disk or bundle is copied; sparse disks; the restore image is deleted after install.

A disk size outside 1 to 4096 GiB is rejected when a config or a snapshot is read and again when an image is created or
grown, so a crafted file can't make the size conversion trap (ADR-0025).

Clones refuse a symbolic-link source and snapshots are identified by their folder, private (0700 folders, 0600 files), as
ADR-0026 records.
