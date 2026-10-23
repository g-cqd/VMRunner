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

(Update 2026-10-23: `AllowControlService` joins the keys: forced to anything but true, the local control service for scripts
and agents (ADR-0056) stays off, agent access is off on every machine, and both switches are locked. The app setting
`runsControlService` is lockable like the others. The status stays proposed.)

(Update 2026-10-23: `AllowProvisioning` joins the keys: forced to anything but true, no machine keeps a provisioning spec
(ADR-0012), so no seed is built or attached, and the spec chooser is locked. The status stays proposed.)
