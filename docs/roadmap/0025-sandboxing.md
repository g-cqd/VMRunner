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

## Done: the boot run (2026-10-22)

The five documented commands were run, plus kernel-boot runs that show a guest talking. An Alpine aarch64 guest starts
and reaches its login prompt under no sandbox, under App Sandbox and under a generated Seatbelt profile, at the standard and
strict levels, with the file-handle NIC and with NAT, headless; a NAT guest gets a DHCP lease under all three. The framework
reports a running machine 0.08 to 0.2 s after `booting` and the first console line follows about 0.1 s later. The profile
as shipped failed with "The boot loader is invalid": one missing kernel value, `hw.pagesize_compat`, found from the log and
by adding rules one at a time, is now in the generator with a test. The numbers, the table of the bisection and what stays
denied are in the study's "Boot run results (2026-10-22)". ADR-0016 is accepted.

## Next

1. Extract the user-mode network stack and the configuration builder from the app target into libraries the helper can link,
   so a helper hosts a real guest network (today the file-handle NIC is on a socket pair nothing serves). Then repeat the boot
   at both levels with a guest that uses the network, which also answers whether the stack works unchanged under App Sandbox.
2. Decide how App Sandbox helpers get files (per-workload signing with exceptions is what works and what `vmr sandbox` does;
   disks cloned into the container or bookmarks were not tried) and, if it changes, record it in a new ADR.
3. Settings model, per-workload override and interface (`SandboxEngine`, `SandboxLevel`), keeping graphical machines in the
   app. The model is settled by ADR-0016; the `custom` level is not exercised.
4. A regression test that boots a workload at each level, reading the helper's events and the guest's console, not the log.
