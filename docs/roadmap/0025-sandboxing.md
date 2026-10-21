---
status: pending
blocked-by: []
date: 2026-10-21
decision: ADR-0016
---
# 0025 — Native sandboxing and Seatbelt, per app or per workload

Study: `docs/sandboxing.md`. Both engines (App Sandbox and Seatbelt) are wanted, one per workload helper; they cannot be stacked (tested). First prototype: a headless helper for one workload, signed with the virtualization
entitlement only, receiving descriptors over XPC; measure boot time and sandbox denials.
