---
status: done
blocked-by: []
date: 2026-10-21
decision: ADR-0009
---
# 0017 — Replace the shell scripts with `vmr`, a library and command plugins

`vmr check|analyzers|build-app|hooks`, fifty end-to-end tests, CI running the same steps.

## Also landed

An exclusive gate lock (a second `vmr check` fails fast naming the holder), a GitHub job summary, and analyzers run
through `vmr` in CI so the lock file is the one source of their versions.
