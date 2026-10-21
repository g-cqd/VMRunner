---
status: done
blocked-by: []
date: 2026-10-21
decision: ADR-0009
---
# 0017 — Replace the shell scripts with `vmr`, a library and command plugins

`vmr check|analyzers|build-app|hooks`, fifty end-to-end tests, CI running the same steps.

## Still owed

A lock so a second `vmr check` on the same tree fails fast instead of waiting on the first.
