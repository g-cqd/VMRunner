---
status: in-progress
blocked-by: []
date: 2026-10-22
---
# 0036 — The order of the remaining work

Rules: every step is atomic, signed, builds and passes `swift run vmr check`; each merged worktree is removed at once and
everything is cleaned up when the work ends (CONTRIBUTING, "Worktrees and cleanup"); agents never start virtual machines; at
most three builds run at once.

| Phase | Work | Entries | State |
|---|---|---|---|
| 0 | **Input latency, before everything else**: audit the input path, add the latency monitor, hold a latency-critical activity while a machine runs, remove main-thread work; the owner measures one macOS and one Linux guest | 0037 | built and merged; the owner's measurements are owed |
| 0 | **The Linux boot display, right after**: the firmware and boot loader text is tiny; the starting scanout must respect the cap whatever was remembered | 0038 | built and merged; the owner's confirmation is owed |
| 0 | **The window and the shown screen**: resizing must realign, rescale and recenter the guest picture and never corrupt it | 0039 | built and merged; the owner's confirmation is owed |
| 0 | **State transitions of a machine**: one explicit state machine, every event and failure path tested | 0040 | built and merged; the owner's confirmation is owed |
| A | Land the branches in flight (network, downloads, container runner), one at a time, with the gate after each; repackage the container runner as its own package before it merges; fix the contradictions between documents and code; write the diary entry | 0034, 0024, 0032 | done: all three branches merged, the container runner is its own package, the documents corrected |
| B | Test support: improve the shared library first, then sync the vendored copy; confirm the suspected defects; port the facilities; adopt the provider seam | 0031, 0035 | in flight: the shared library's utilities are being upgraded; the sync follows |
| C | Naming ADR and renames, then the packages in order | 0032 | naming ADR and the renames done except `TestKit`; seams in flight |
| D | Performance and memory leftovers | 0033 | open |
| E | Remaining contributions to the shared library | 0035 | the Base64 patch awaits review; the rest follows the stack package |
| F | The rest of the security backlog | 0034 | in flight: signed AlmaLinux, Rocky Linux and Fedora releases, key expiry, the network leftovers, the gate lock, the installer clones and the review follow-ups are done; Debian netboot, the floor opt-in and coverage-guided fuzzing wait for the owner |
| G | Features in dependency order: the workload abstraction (after the container and sandbox first runs), managed preferences (0013), the automation server (0005), host information (0011), realism (0012), the VPN probe and kill switch (0010), provisioning (0016), Developer ID and notarization (0021), private interfaces (0029, after the owner tags the packages) | 0005 to 0029 | the app's code starts a container through the workload seam (0024, ADR-0057; tested with fake runners; a first real run from the app started and stopped containers, and 0024 says what it did not show), managed preferences (0013), host information (0011), realism (0012) and the kill switch (0010) built and their review follow-ups done, the owner's checks owed; the in-guest VPN probe waits for an ADR; the rest open |
| H | Deferred: Linux GPU (needs a macOS 27 host), the macOS OCI store, saved-state encryption (after a throughput measurement) | 0014, 0024 | deferred |

Owner-gated: the guest checklist (0030), the sandbox boot run (0025), the real run of a container machine from the app (0024),
package tags (0029), a Developer ID certificate (0021), a macOS 27 host (0014). The container runner's first run is done
(2026-10-22); the runner is built, signed, bundled in the app at `Contents/Helpers/ContainerRunner` and started by the app,
and agents still never run it: `vmr container-run` needs the owner's `--boot`.

Not planned, with reasons in the studies: depending on the owner's libraries or on swift-crypto from the app; a lenient
Base64 decoder for armor; splitting the configuration, library and controller types before they are stable; encrypting disk
images; making the benchmark job required before it has stable runs on hosted runners.
