---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0016
---
# 0025 — Native sandboxing and Seatbelt, per app or per workload

Study: `docs/research/sandboxing-2026-10.md`. Both engines (App Sandbox and Seatbelt) are wanted, one per workload helper; they cannot be stacked (tested). First prototype: a headless helper for one workload, signed with the virtualization
entitlement only, receiving descriptors over XPC; measure boot time and sandbox denials.

## Done: the helper and its probes, without a machine

- `VMHelper` (`Sources/VMHelper`) and `VMHelperCore` (`Sources/VMHelperCore`): a headless helper that reads a JSON descriptor,
  reports line-delimited JSON events and exits with a `sysexits.h` status; `--dry-run` validates the configuration,
  `--probe` tries what a helper needs, `--start` boots. The descriptor arrives by path or on standard input, not yet over XPC.
- `vmr sandbox run|profile`: launches the helper under App Sandbox (a bundle signed with the descriptor's paths as
  temporary-exception entitlements), under a generated Seatbelt profile with `sandbox-exec`, or unsandboxed as the control,
  and reports denials, boot time and whether user-mode networking and name resolution work inside the sandbox.
- Run for real, without a machine: every engine and level validated both test configurations; the probe shows which
  operations each refuses. Results and what they mean for the engine and level model: the study's "Probe results".

## Blocked on the owner: one boot run

Agents never start a virtual machine, so whether a guest boots inside either engine is open until the owner runs the five
commands in the study's "The owner's boot run" and reports the output. A failure under `seatbelt` is expected to be a missing
Mach service or file rule that the report's denials name.

## After the boot run

1. Fold the Mach services and rules the boot needs into the profile generator, and record boot time per engine.
2. Extract the user-mode network stack and the configuration builder from the app target into libraries the helper can link,
   so a helper hosts a real guest network (today its NIC is on a socket pair nothing serves).
3. Decide how App Sandbox helpers get files (per-workload signing with exceptions, or disks cloned into the container) and
   record it in the ADR's "What this does not decide".
4. Settings model, per-workload override and interface (`SandboxEngine`, `SandboxLevel`), keeping graphical machines in the app.
