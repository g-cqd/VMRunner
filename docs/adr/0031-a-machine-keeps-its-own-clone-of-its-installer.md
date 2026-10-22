---
status: accepted
date: 2026-10-22
---
# 0031 — A machine keeps its own clone of its installer

This ADR amends [ADR-0015](0015-installers-come-from-the-vendors-over-https-with-pinned-hosts.md), whose decision 2 says a
cached installer is re-verified before it is reused. It builds on [ADR-0003](0003-disks-are-cloned-never-copied.md).

## Context

Setup verified an installer once, then stored the path of the shared cache file in the machine's configuration, and the
builder attached that path at every start without looking at it again. The cache was a live attachment target. Any later
change to the file, by another setup, a damaged or replaced file, or an attacker with the user's rights, reached the guest
unchecked; and a setup for one machine could delete the file another machine was attached to, because the cache was keyed by
file name alone and a file that failed one machine's checksum was removed. A link at the cache path was followed when the
file was hashed.

## Decision

1. The shared cache is filed by content: `Images/<sha256>/<name>`, or under a hash of the claim when there is no usable
   SHA-256. Two checksums for one file name never share a path, and a file that fails its own slot's checksum is the only
   file a setup deletes.
2. Setup clones the verified file into the machine's bundle as `Installer.iso` (`clonefile`, ADR-0003) and stores that path.
   The machine boots from its bundle copy; the cache is never attached. A file the user chose is attached where it is.
3. Hashing and attaching refuse anything but a regular file and never follow a link (`O_NOFOLLOW`, then `fstat`). A link at a
   cache path is an error, not something to delete or read through.
4. A file that appears at the cache path while a download is verifying is replaced by the verified one, not trusted.
5. A duplicated machine, whose configuration still names the source's `Installer.iso`, attaches its own clone.

## Consequences

An installer costs no extra space until the cache is cleared, then its bundle copy holds the blocks. A machine made before
this decision still stores a path into the flat cache; it keeps working and is not migrated, so clearing the downloaded images
removes its installer until the user chooses one again. Those old files sit outside the new layout and are cleared with the
rest. Cloning needs the cache and the machines on one APFS volume, which the default location gives.

## What this does not decide

Verifying the bundle copy again at every start, which would cost a full read of the installer each time; the copy is in the
user's private folder, and an attacker who can write there can already write the disk.

(Update 2026-10-22: a machine made before this decision is now migrated at launch. When its configuration names a file
directly in the old flat cache and the user approved that path for it, the file is cloned into its bundle and the clone is
approved too. A macOS install also reads its own clone of the restore image, never the cache file, and a clone that a crash
left behind is deleted at the next launch.)
