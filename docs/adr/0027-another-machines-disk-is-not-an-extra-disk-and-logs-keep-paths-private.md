---
status: accepted
date: 2026-10-22
---
# 0027 — Another machine's disk is not an extra disk, and logs keep paths private

## Context

An extra disk is any file the user (or a config) names. Pointing one at `Machines/<id>.vm/Disk.img` attaches another
machine's disk, so two guests can write the same image or one reads the other's data, and the exposure summary showed only
the file's last component, so two disks called `data.img` looked alike. Separately, the logs recorded error descriptions with
`privacy: .public`, and those descriptions often contain the host path of the file that failed, which is exactly what
`Log` promises to redact. The cache-clean-up check compared a path prefix as text, so a file in `Images2` counted as inside
`Images`.

## Decision

1. A file inside the Machines folder is refused as an extra disk: when a config is read, by the file picker and when the
   storage devices are built. Containment is decided on whole path components after links and `..` are resolved
   (`AppPaths.isInside`); the cache clean-up uses the same function.
2. The exposure summary shows the full path of every extra disk.
3. A failure is logged as its kind (`Error.logKind`, the domain and code) in the clear and its description `.private`.
4. The log subsystem is the app's bundle identifier when there is one, and otherwise the placeholder that
   `Resources/Info.plist` carries; a test keeps the two equal.

## Consequences

Attaching a disk that is kept in the Machines folder needs it moved out first. Logs from a user's Mac still say what kind of
failure happened without saying where.

## What this does not decide

Whether two running machines may share any writable extra disk; the help already warns against it.
