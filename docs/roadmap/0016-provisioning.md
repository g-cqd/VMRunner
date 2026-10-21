---
status: pending
blocked-by: []
date: 2026-10-21
decision: ADR-0012
---
# 0016 — Unattended installs and scripts at install steps, Kubernetes-compatible

Study: `docs/provisioning.md`. Build in order: spec parser and seed builder, installer seed media, vsock agent.

## Done when

A cloud image boots with a generated seed, runs a `first-boot` script whose hash the host checked, and reports `ready`.
