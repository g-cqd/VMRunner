---
status: accepted
date: 2026-10-22
---
# 0024 — Host paths in a config are honoured only after the user approved them

## Context

A machine's `config.json` names host paths the guest gets: shared folders (read-write unless marked otherwise), extra
disks and the installer image. The file is plain data in a folder the user can copy, sync or receive, and the app started
whatever it said. A bundle copied from elsewhere could grant a guest read-write access to a host directory, and nothing in
the Start path surfaced it. ADR-0004 makes the exposure summary say what a machine can reach, but a summary the user never
opens does not stop a start.

## Decision

1. The app records, per machine, the host paths the user approved: kind (shared folder, extra disk, installer image), the
   path and whether the guest may write. A writable approval covers the read-only use of the same path, not the reverse.
2. The record lives in one file beside the machines folder, outside every bundle, so copying a bundle does not copy its
   approvals. Only the user's own actions write it: the editor's file pickers, the New Machine sheet (including a local
   installer image chosen there), a download the app made itself, a duplicate (which inherits what its source had) and
   the "Approve and Start" button. A settings change never writes it, because the settings in memory may have been read
   from a file on disk.
3. Start checks the configuration against the record. With paths missing it shows them in an alert that offers "Approve and
   Start"; a `--start` launch has nobody to ask, so it logs and does not start.
4. Migration: when no approvals file exists the app has never recorded approvals, so the machines already on disk were made
   by the user under an earlier version and their current paths are approved once, when the library first loads, and the
   file is then written. From then on a bundle that appears without a record, such as a copied or downloaded one, has
   nothing approved, even on a fresh install with no machines. A file that exists but cannot be read approves nothing.

## Consequences

A user who switches an approved read-only folder to writable in the editor is asked once at the next Start, which is the
point. Deleting a machine drops its record. Approvals are not pruned when a path is removed from a machine.

## What this does not decide

Whether the guest may be handed a path that moves later (a symlink swapped after approval), and sandboxing the host side of
the shares; see the sandboxing study.
