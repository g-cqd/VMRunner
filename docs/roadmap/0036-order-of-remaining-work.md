---
status: in-progress
blocked-by: []
date: 2026-10-22
---
# 0036 — The order of the remaining work

Rules: every step is atomic, signed, builds and passes `swift run vmr check`; each merged worktree is removed at once and
everything is cleaned up when the work ends (CONTRIBUTING, "Worktrees and cleanup"); agents never start virtual machines; at
most three builds run at once.

| Phase | Work | Entries |
|---|---|---|
| 0 | **Input latency, before everything else**: audit the input path, add the latency monitor, hold a latency-critical activity while a machine runs, remove main-thread work; the owner measures one macOS and one Linux guest | 0037 |
| A | Land the branches in flight (network, downloads, container runner), one at a time, with the gate after each; repackage the container runner as its own package before it merges; fix the contradictions between documents and code; write the diary entry | 0034, 0024, 0032 |
| B | Test support: improve the shared library first, then sync the vendored copy; confirm the suspected defects; port the facilities; adopt the provider seam | 0031, 0035 |
| C | Naming ADR and renames, then the packages in order | 0032 |
| D | Performance and memory leftovers | 0033 |
| E | Remaining contributions to the shared library | 0035 |
| F | The rest of the security backlog | 0034 |
| G | Features in dependency order: the workload abstraction (after the container and sandbox first runs), managed preferences (0013), the automation server (0005), host information (0011), realism (0012), the VPN probe and kill switch (0010), provisioning (0016), Developer ID and notarization (0021), private interfaces (0029, after the owner tags the packages) | 0005 to 0029 |
| H | Deferred: Linux GPU (needs a macOS 27 host), the macOS OCI store, saved-state encryption (after a throughput measurement) | 0014, 0024 |

Owner-gated: the guest checklist (0030), the sandbox boot run (0025), the container first run (0024), package tags (0029),
a Developer ID certificate (0021), a macOS 27 host (0014).

Not planned, with reasons in the studies: depending on the owner's libraries or on swift-crypto from the app; a lenient
Base64 decoder for armor; splitting the configuration, library and controller types before they are stable; encrypting disk
images; making the benchmark job required before it has stable runs on hosted runners.
