---
status: accepted
date: 2026-10-22
---
# 0026 — A machine bundle is untrusted input and private output

## Context

ADR-0024 and ADR-0025 treat the contents of `config.json` as untrusted. The rest of a bundle is just as easy to copy or hand
over: the identity a snapshot states about itself, a link where a folder or a disk image should be, and the permissions on
what the app writes. A copied snapshot folder aliased the original, a link in the machines folder or as `Disk.img` let a
bundle's owner point the app at any file, and the settings, the snapshots and the memory image of a suspended machine were
written with the default permissions.

## Decision

1. A snapshot's identity is its folder name. A folder whose name differs from the id in its `snapshot.json` is skipped,
   as `VMLibrary` already skips a machine folder whose name differs from its config's id.
2. A symbolic link is not a bundle: the library ignores one in the machines folder. `APFS.clone` refuses a source that is a
   symbolic link and passes `CLONE_NOFOLLOW` as well. Cloning the target would copy a file the bundle has no business with;
   cloning the link would make a disposable copy that writes through to the original.
3. What the app writes into a bundle is for the user only: snapshot folders are 0700, and `config.json`, `snapshot.json`
   and the saved memory image are 0600 (the bundle folder itself was already 0700).

## Consequences

A user who deliberately links `Disk.img` to a disk elsewhere can no longer duplicate, snapshot or run that machine as
disposable; the error says why. The files of machines made before this change keep their old permissions until the app next
writes them; the 0700 bundle folder is what protected them.

## What this does not decide

Whether `Disk.img` itself, or the other files a bundle holds, may be links that the Virtualization framework follows when the
machine starts.
