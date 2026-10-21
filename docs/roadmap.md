# Roadmap: every request, its state, and what is left

Compiled from the owner's requests across the build sessions. "Done" means implemented, tested and committed. "Investigated"
means a written study exists in `docs/` but nothing is built. Nothing marked done has been run against every guest on a
real machine unless it says so.

## Requests

| # | Request | State | Left to do |
|---|---|---|---|
| 1 | Simplest VM runner, SwiftUI, macOS guests from ipsw.me, Linux (CentOS), extensive in-app configuration | Done | – |
| 2 | Startup/UEFI display size: aspect-compatible, text not tiny; later "size wrong once the UI is shown" | Done (pinned MAC and starting size, Linux 1280 cap, follows window) | – |
| 3 | Hide the toolbar in full screen; full-screen transition failed | Done (bare machine view when immersive) | – |
| 4 | In-depth settings to extend or limit guests, sandboxing, secure and very hardened presets | Done (Standard, Contained, Isolated, Hardened) | Per-workload host-side sandbox: see 30 |
| 5 | APFS copy-on-write everywhere | Done (duplicate, snapshots, disposable machines, sparse disks) | – |
| 6 | MCP server, CLI and terminal automation, screenshots and recording, isolation, for AI coding agents | Investigated (`automation.md`) | Build it: local socket + MCP over stdio, per-client capability tokens, screenshot via ScreenCaptureKit window capture, recording, serial console and vsock terminal |
| 7 | Harden and bump all Swift settings and code-quality enforcement | Done (strict memory safety, warnings as errors, upcoming features, SwiftLint strict + custom rules, swift-format, sanitizers, coverage ratchet) | – |
| 8 | IP blocks, URL blocks, VPN detection; arcleak, dolly, deadwood; Swift 6.4 | Done (engine, analyzers, host VPN monitor) | UI and enforcement wiring: in progress (see 20) |
| 9 | RegexBuilder everywhere | Done (no `NSRegularExpression`; RegexBuilder in the parsers) | Keep new code on RegexBuilder |
| 10 | More distros, official Debian images, clean providers | Done for Debian and CentOS Stream; Alpine is a candidate | Owner decision: which of the candidates in `Catalogs.candidates` to register (12) |
| 11 | Move logic to view models, scope views atomically | Done | Keep new screens to the same pattern |
| 12 | Limit Linux providers to very trustworthy ones, propose a list | Proposed, awaiting a decision | Owner picks the list; then register and add each provider's checksum/signature path |
| 13 | In-app documentation of every feature, near where it is configured, for beginners and experts | Done (tooltips, help popovers, searchable Help window) | Every new feature adds its topic (network policy, provisioning, containers, sandbox) |
| 14 | Guest VPN detection; guest traffic follows the host's network without hiccups | Done in the user-mode stack (detector, path-change reset) | Wiring (20); optional in-guest probe over vsock; metered/constrained-network guard; kill-switch by swapping the NIC attachment |
| 15 | Forward host information (battery, power, thermal, network path, time zone) per VM, opt-in | Not started | Per-category opt-in, read-only share or vsock channel, exposure lines in security profiles, help |
| 16 | Make a guest not know it is a VM (for sandbox analysis, privacy and unbounded agents) | Investigated (`analysis-sandbox.md`) | Realism knobs: NVMe disk and serial identifiers, MAC vendor prefix, fresh identity per disposable start; honest help on what a guest can still tell |
| 17 | MDM: can profiles be forwarded to guests? | Investigated (`mdm.md`): not possible for ADE/profiles; managed preferences work for the app itself | Managed-preferences policy engine (`objectIsForced`) that locks settings |
| 18 | Commit atomically | Ongoing (every commit builds and passes; signed) | – |
| 19 | 3D acceleration in the VM | Investigated (`gpu-acceleration.md`): macOS guests get Metal, Linux guests have none under this framework | Spike a custom virtio-gpu device (macOS 27 only) |
| 20 | Allow-list or deny-list for ports, IPs, connections, domains, URLs | Engine and enforcing network stack done and committed | Wiring and editor UI: in progress; real-guest validation |
| 21 | Install or run from an ISO; Windows on ARM; GPU for all | ISO option done; Windows investigated (`windows-on-arm.md`): not supported | Windows stays unsupported unless an experimental slice is wanted (not recommended) |
| 22 | Shell scripts become Swift commands/plugins with end-to-end tests | Done (`vmr`, `DevTools`, three command plugins, 50 end-to-end tests) | Make `vmr check` refuse to run twice at once on the same tree |
| 23 | Everything through a high-performance lens; use the test tooling (TaskProvider, AsyncEventProbe, ManualClock) | Partly: TestKit vendored (clock, probe, gates, allocation counter); debounced settings writes; allocation ceilings on the policy decision; zero-allocation hot paths in the network stack | Extract testable runtime-limit and debounce seams; precompute the help search index; profile checksum throughput; dedupe the network tests' own allocation counter with TestKit; tighten the policy-decision ceilings |
| 24 | Library review: Subprocess and other Apple/swiftlang packages where they reduce code | Done (swift-subprocess, swift-argument-parser, swift-async-algorithms, swift-collections; others rejected with reasons) | – |
| 25 | CI and quality as in the other repositories, state of the art | Mostly done (merge queue, provenance-attested release, cache hygiene, Scorecard, dependency review, CODEOWNERS, templates, pre-push) | Push to GitHub and apply the ruleset; Developer ID signing and notarization (unverified under the virtualization entitlement); benchmark/allocation regression gate; TerminalKit was not found locally |
| 26 | Never mention the other repository | Done | – |
| 27 | MIT licence | Done | – |
| 28 | Install from ISO and run scripts at install steps, Kubernetes-compatible | Investigated and designed (`provisioning.md`) | Build in order: seed builder and spec parser, installer seed media, vsock agent |
| 29 | Containers from Apple's primitives, OCI images from various sources, macOS containers, parity with VMs, feasibility of every feature for both | Investigation under way (`containers.md` when finished) | Decide after the study |
| 30 | Native sandboxing, `sandbox-exec` and Seatbelt for VMs and containers, app-wide or per workload | Investigation under way (`sandboxing.md` when finished) | Decide after the study |

## Open decisions for the owner

- Which Linux providers to register (12).
- OpenPGP verification of installer checksums: none today (checksums come from the vendor over HTTPS).
- Whether to ship an experimental Windows slice (not recommended).
- Debian netinst redirect policy.
- Whether Developer ID distribution is wanted (needs a real-hardware check of the virtualization entitlement first).

## Known weak spots

- The user-mode network stack and the in-app lists have never been exercised with a real guest. CI cannot run a VM.
- Secure Boot support is written for macOS 27 and could not be exercised on the development machine (macOS 26.7).
- `VPNMonitorTests.stopReturnsToUnknownAndIgnoresLaterSnapshots` counts `Task.yield()` calls and can fail under load; it
  should use the test clock and probe.
