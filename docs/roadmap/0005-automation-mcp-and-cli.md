---
status: pending
blocked-by: []
date: 2026-10-21
---
# 0005 — A local control surface for AI agents and scripts

Study: `docs/automation.md`. A local socket plus MCP over stdio, per-client capability tokens, screenshots through
ScreenCaptureKit window capture, recording, and a serial or vsock terminal, each isolated from the host.

## Done when

An agent can start a machine, read its state, take a screenshot and type into the guest through a token that grants only
those capabilities, with tests for the capability checks.
