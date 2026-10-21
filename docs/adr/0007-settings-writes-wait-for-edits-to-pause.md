---
status: accepted
date: 2026-10-21
---
# 0007 — Settings writes wait for edits to pause

## Context

Each keystroke in a settings field rewrote `config.json` atomically on the main actor.

## Decision

1. `ConfigPersistence` keeps the newest config per machine and writes it once edits have paused for 400 ms, using
   `debounce` from swift-async-algorithms on an injectable clock.
2. Quitting flushes; deleting a machine drops its pending write; a failed write still reaches the user as an alert.
3. Tests drive the debounce with the test clock, so none of them sleeps.

## Consequences

The file on disk can lag the model by up to the quiet period. Anything that reads the files on disk must flush first.

## What this does not decide

Moving the write off the main actor.
