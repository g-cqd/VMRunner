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

A policy engine that reads forced keys and locks the matching controls is the work to build. See `docs/mdm.md`.

## What this does not decide

Which settings are lockable first.
