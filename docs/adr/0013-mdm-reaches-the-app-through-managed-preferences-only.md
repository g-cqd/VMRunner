---
status: proposed
date: 2026-10-21
---
# 0013 — Mdm reaches the app through managed preferences only

## Context

The question was whether MDM policies can be forwarded into guests.

## Decision

1. Configuration profiles, supervision and automated enrollment cannot be forwarded to a guest.
2. Organisations can control the app itself through managed preferences (a forced `com.apple.ManagedClient.preferences`
   payload, read with `objectIsForced`), locking settings the user must not change.

## Consequences

A policy engine that reads forced keys and locks the matching controls is the work to build. See `docs/research/mdm-2026-10.md`.

## What this does not decide

Which settings are lockable first.

(Update 2026-10-22: a first set of keys is built under this proposal: `AllowSharedFolders`, `AllowClipboardSharing`,
`AllowMicrophone`, `AllowSuspend`, `AllowHostInformation`, `RequireDisposableMachines`, `MaxRuntimeMinutes` and the app's
own settings. A forced value of the wrong type restricts. A forced `MaxRuntimeMinutes` of 0 sets no limit, by the owner's
decision; any other value outside 15 to 1440 becomes 15. The status stays proposed until the owner accepts the key set.)
