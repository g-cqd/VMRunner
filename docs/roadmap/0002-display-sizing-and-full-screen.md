---
status: done
blocked-by: []
date: 2026-10-21
decision: ADR-0002
---
# 0002 — Legible, aspect-correct guest display and a clean full-screen

The guest starts at the window's aspect ratio with Linux capped at 1280 pixels wide, follows the window afterwards, pins
the size and MAC so saved state restores, and replaces the split view with the bare machine view in full screen.
