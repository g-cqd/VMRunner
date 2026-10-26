# REVIEWED-Q: independent pre-dispatch review of chain Q (virtio-gpu 2D feasibility runner)

Reviewer: second pass, adversarial. Base `main` at `a0c87bc`, detached scratch worktree, cards applied in order exactly as written
(files extracted mechanically from the code blocks, the non-file edits by hand), `swift-format`, build and package tests per card,
`swift run vmr check` after the last card, the package's own `swift test`. No machine was started, no window opened, `--window`
never passed (not even to `--dry-run`). Scratch worktree and every `/tmp` file removed at the end.

## Verdict

| Card | Verdict | One line |
|---|---|---|
| Q01 | ready | anchors match; `--describe` output identical; layering tests catch all four mutations I tried |
| Q02 | ready | anchors/compile/tests as claimed; both dry-runs reproduce; scratch-directory check is weaker than decision 8 says (see below) |
| Q03 | ready after edit | 25 tests as claimed; decoder survived my hostile corpus; one prose edit, one dispatch-order caveat |
| Q04 | ready | 40 tests as claimed; no trap, partial write or accounting error under ~1.2 million hostile operations; one CPU-stall risk |
| Q05 | ready | 54 tests as claimed; the card's random state test is shallow (1 successful transfer in 3000 rounds) but the deep paths are covered elsewhere |
| Q06 | ready after edits | 58 tests as claimed; wiring correct by reading; unbounded per-element log line on I/O failure fixed, probe made one-shot |
| Q07 | ready after edits | 63 tests as claimed; PNG writer and all 8 pixel formats verified end to end; same fix as Q06; `--window` removed from the dry-run step |
| Q08 | ready | docs gate passes; one honesty/date decision for the owner |
| Q-RUN | ready after edits | conditions meet CONTRIBUTING; probe script quoting verified; 5 edits (indentation trap, fresh-path check, probe-ordering, helper process) |
| INDEX-Q | ready after edits | 3 edits (decision 8 facts, Q03 ordering, edit disclosure) |

Gate: `swift run vmr check` on the full chain 8/8 PASS (format, swiftlint, docs, workflows, policy, build, test, analyzers with
arcleak, dolly, deadwood PASS), run twice: once on the cards as written, once after my edits. Package run `63 tests in 11 suites
passed` both times. Per-card package counts reproduced: Q03 25, Q04 40, Q05 54, Q06 58, Q07 63.

## Card edits (14 edit operations in 5 files; Q01, Q02, Q04, Q05, Q08 untouched)

1. `Q03.md`: Why paragraph said "the device the spike builds"; now "this feasibility study builds" (planning word in text an executor may copy).
2. `Q06.md`, `GPUDevice.swift` block (six replacements) and the Why sentence:
   - `could not read a request...` and `could not write an answer...` were logged on every failing element: unbounded output under a
     misbehaving or hostile guest. Now `noteFailure(_:)` counts every failure and prints the first; `commands.log` gets a line
     `failed reads and writes of a request or an answer: N`.
   - The config-change probe task was started on every `DRIVER_OK` (a guest resetting in a loop spawned a task, an `update` and two log
     lines per cycle). Now armed once (`probeArmed`), matching the recorder, which only watches the first update.
   - Re-compiled in the scratch chain (build, `swift-format`, `swiftlint --strict` 0 violations, package tests, full gate 8/8 again).
     The Q06 text differs from the Q07 text only by the lines Q07 adds for the sinks (diffed).
3. `Q07.md`: same `GPUDevice.swift` edit; the "145 lines" check became 155 (the line count Q06 now leaves); step 13 no longer passes
   `--window` to the dry run (the flag's parsing is covered by `RunnerArgumentsTests`; the dry run exits before any AppKit use, but the
   standing rule is that the agent never passes it).
4. `INDEX-Q.md`:
   - decision 8 now records what `--dry-run` showed (below), so the owner decides knowing it;
   - "Q03 may be dispatched before Q02" now says what that costs (test counts 7 lower in Q03 to Q05) and recommends number order;
   - the "byte-identical" claim now points at this file for the two exceptions.
5. `Q-RUN.md`:
   - user-data/entitlements blocks are indented 3 spaces in the card (list nesting): copied literally, `#cloud-config` is no longer in
     column 0 and cloud-init ignores the file. Now says remove them, and write the file with a quoted heredoc or the Write tool (the script
     holds `$1`, `$(...)`, backslashes);
   - new stop condition: any `/tmp/vmr-gpurun*` path already exists (the runner reuses an existing directory and its check is by name);
   - notify evidence: the config update (30 s after `DRIVER_OK`) can precede the first probe (cloud-init final stage, no network, may start
     30 to 120 s after boot), so the two `/proc/interrupts` snapshots may not show it; `commands.log` is the deciding evidence, compare times;
   - cost: the guest's 2048 MiB live in the framework's helper process, not the runner; read (never signal) that process too.

## Findings per card

Q01. Anchors for `.vmr.json`, `.swiftlint.yml`, `ModuleBoundaryTests.swift` each match once. Diff of the three files is confined to the
package paths (two lines each, one test, one argument). Shared-settings block identical. Layering test mutation check (applied together,
all reported by name): `import VirtioGPURunnerCore` as `internal import` in a root `Sources` file, the word `VirtioGPU` in the root
manifest, `import AppKit` in Core, `.package(` in the nested manifest. Limits: only root `Sources` is scanned for imports (root `Tests`
and `Plugins` are not), and the root `Package.resolved` is not read. Both are covered in practice by the manifest check.

Q02. All anchors fine. Reproduced: unsigned `--dry-run` `VZErrorDomain` code 2, ad hoc signed with only the virtualization entitlement
`configuration valid` and no `run` directory written. Limits enforced in the parser (2 CPUs, 1024 to 2048 MiB, 10 to 3600 s, default 900).
Scratch-directory check, tried with `--dry-run` (writes nothing): a symlink to the home folder and a symlink to `~/Library` are accepted;
`~/library/x` and `~/LIBRARY` are accepted (case-insensitive volume, the comparison is case-sensitive); `/private/etc/x` is accepted (usage
text says "under /tmp", nothing enforces it). Decision 8 admitted the link case only. Risk is low for an owner-run tool given Q-RUN passes
a fresh `/tmp` path (now checked), but the INDEX should not read as a guarantee. Other: `--disk` may name any absolute path and is attached
writable (Q-RUN uses a downloaded copy); the pid file is written before configuration validation, so a failed start leaves a stale pid
(Q-RUN only signals pids it recorded itself, so no harm).

Q03 and Q04 hostile corpus (my own throwaway tests, run in debug, removed afterwards; ~1.2 million handled requests plus tables):
- wrong sizes: every command type (known and unknown) at every length 0 to 117, with flags/fence/ring set, both queues: no trap, answers always 24 or 408 bytes;
- `nr_entries` 0, 16384, 16385, 1 000 000, 0x1000_0000, 0x8000_0000, `UInt32.max`: refused before any reserve (RSS flat); 16384 entries of
  `UInt32.max` length accepted as layout (arithmetic in `UInt64`, no overflow); 16384 entries plus 1 byte trailing and plus 2 bytes: accepted/refused as designed;
- entries overlapping, outside RAM, wrapping `addr+len`, zero length; offsets `UInt64.max`, `max-3`, `1<<63`, `1<<32`, `0xFFFF_FFFF_FFFF`;
  rectangle x/width `UInt32.max`; resources 1 x 16 777 216, 16 777 216 x 1, 4096 x 4096, 4097 x 4096 (refused), `UInt32.max` squared (refused);
- resource id 0, `UInt32.max`, reuse after unref, recreate under the same id with another size while a scanout once pointed at it,
  unref while scanout set (scanout cleared), double attach (`ERR_UNSPEC`), detach then transfer, set scanout resource 0, scanout id `UInt32.max`;
- 1.8 million create requests with distinct ids: exactly 256 accepted, count and bytes stay at the limit, RSS 232 MiB peak (the 64 MiB
  resource tests included); 1.8 million create/unref churn on reused ids: accounting returns to the sum of live resources;
- 400 000 random and mutated structured requests (interesting-value generator, fences/flags random, small limits), after every request:
  `totalBytes` equals the sum of live pixel arrays, count within limit, scanout references an existing resource and fits it, every non-OK
  transfer left every pixel array byte-identical (no partial write); 150 000 random byte strings up to 3000 bytes and 50 maximum-size attach
  requests (limit and limit +/- 1);
- 18 000 directed transfers against an independent oracle (random split backing over a known memory image, random offsets/rects, some
  out of bounds): every OK result matches the oracle byte for byte, every refusal either leaves pixels unchanged or is a real
  out-of-backing span (14 342 OK, 3 658 refused);
- 100 000 random headers to the answer encoder: unknown flags never echoed, fence id/context only with the fence flag.
Result: no trap, no unbounded allocation, no partial write, no accounting error, no decoder/store bug.

One real risk, not a bug: CPU stall. `transferToHost2D` does one `pieces` call and one guest-memory copy per row, and a resource
may be 1 x 16 777 216 (64 MiB). A transfer of all its rows took 21.9 s in a debug build with an in-memory fake (RSS 104 to 232 MiB); the
real adapter calls `guestMemoryMapping` per piece, so slower. A well-behaved Linux driver never does this; a hostile guest can block the
main queue (so also the time limit, logging and the notification loop) for that long, once per command, repeatedly. Bounded, not a hang.
Optional hardening for a later change: coalesce rows when `rowBytes == stride`, or cap rows per command. I did not edit it.

Q05. The random tests (`GPUDeviceStateRandomTests`) were instrumented: of 3000 plausible rounds only 1 transfer succeeded, 8 flushes
produced a picture, a scanout was set in ~800 rounds. They do exercise decoder, limits and the store's refusal paths; the success paths
are covered by the table tests and, in my run, by the oracle test above. Not a defect, but the card text "reach deep states" overstates
it. `ScanoutImage.rgbx` does `Int(width) * Int(height) * 4` unchecked: `UInt32.max` squared would trap, unreachable from the guest because
the store bounds every `ScanoutUpdate` (the type has no public initializer).

Q06 (by reading, plus compile/tests/dry-run):
- exactly one `returnToQueue()` per element on every path: it is the first statement of `service` as a `defer`; the oversize path, read
  error and answer paths all return through it; `nextElement()` is called once per element;
- one read: `readBuffersAvailableByteCount` then one `readBytes(withExactLength:)` of that length (<= `maxCommandBytes`); an oversize
  request reads only its 24-byte header; the decoder and state work on the copy. Backing pieces are read once per byte per transfer
  (intentionally re-read on each transfer: the guest redraws), through one bounds-checked copy (`mapping.length >= count`, count > 0);
  the entry list itself is copied from the request copy. No double read of one request;
- answer written only if `writeBuffersAvailableByteCount >= response.count`, otherwise counted (first one logged) and nothing written;
- the single `unsafe` block is bounded by the mapping length; Core contains no `unsafe`, `try!` or `as!` (grep);
- the delegate is `@MainActor`, the device queue is `.main`, the runner holds the `GPUDevice` strongly and is itself held by
  `withExtendedLifetime(runner) { dispatchMain() }`;
- fixed (edit 2): unbounded failure logging; probe task per `DRIVER_OK`. Remaining, not edited: `while let element = queue.nextElement()` has
  no per-notification cap (a guest that refills the ring as fast as it is drained keeps the main queue, and with it the time limit, busy);
  the CPU stall above; lifecycle lines (`device reset`, `DRIVER_OK`) are one per guest event.
- the notify measurement design is sound: the 5 s wait of the Linux driver after its first display-info request separates "returnToQueue
  notifies" (next command in milliseconds) from "does not" (about 5 s then stall); `events_read` set through `update(_:)` makes a notified
  driver issue GET_DISPLAY_INFO again, recorded host-side with times (`display info requested after the update at`).

Q07. Built a throwaway harness inside the scratch package (temporary dependency of the test target on the executable target, reverted):
all 8 virtio formats written through `ScanoutDump` and decoded back from the PNG: every pixel of an 8 x 4 picture has the expected
R, G, B and opaque padding for each format (offsets cross-checked against the Linux/DRM little-endian mapping: `b8g8r8x8` is memory order
B,G,R,X; `x8b8g8r8` is X,B,G,R; `a8r8g8b8` is A,R,G,B; the others likewise). Throttle: first picture at once, five more within 1 s write
nothing, the tick at 1000 ms writes the newest, `finish()` writes only a pending picture and the file holds the newest one; no
`scanout.png.partial` left; final mode 0600; `replaceItemAt` leaves only `scanout.png` in the directory. A zero-size update logs "could not
make a picture" and writes nothing. Nits (not edited): the temporary file is created by ImageIO with the process umask (normally 0644) and
chmod-ed to 0600 afterwards, so "private temporary file" is true only after the chmod (the 0700 directory protects it when the runner
created it); a failed `Finalize` leaves the `.partial` until the next write; encoding a 4096 x 4096 scanout once a second runs on the main
queue. The leak fix: the tick `Task` captures `self` weakly and the loop ends with the runner; the `ScanoutDump` log closure captures the
device strongly while the device holds the sinks (a cycle that lives as long as the process; arcleak passes it). `--window` code path
untouched by me; `NSApplication.run()` is only reached with the flag.

Q08. Anchors fine (ADR last line, no `-02` diary before). Gate `docs` step passes. Texts honest about "NOT RUN". Row 9 of the diary table
("PNG writer ... TESTED (outside the runner)") cites a probe that is not in the repository (no test covers `ScanoutDump`); I reproduced it
independently, so the claim is true, but a reader of the repo cannot re-run it. See decision 9 below on the date.

Q-RUN. CONTRIBUTING conditions: scratch directory under `/tmp` (build worktree is the only thing outside, removed at the end; download
space check present), 2 CPUs / 2048 MiB / `--max-seconds 600` plus a 660 s `kill` backstop, only recorded pids signalled, headless, no
screenshot (the PNG is read as a file), no `--window`, cleanup list complete and includes `CFNetworkDownload_*`, download capped at
1 GiB both by HEAD and `--max-filesize`, HTTPS only, SHA-512 checked, no signature (said). Gaps against the `vmr guest` text: no
signature check (stated honestly). Probe script: extracted the user-data, parsed it with Ruby's YAML (valid; `permissions` is the string
`0755`; `runcmd` gives four `[sh, -c, ...]` entries, the `printf` string reaches `sh` as `\033[2J\033[H...\n` and printf turns it into
`ESC[2J ESC[H VMRUNNER GPU SCANOUT TEST LF`, checked by running only that `printf`), `sh -n`/`bash -n` accept the script, and a
host run of the script against a fake sysfs tree (paths rewritten, output to a scratch file, no guest command executed) printed the
expected `pci ... vendor=0x1af4 device=0x1050 class=0x038000 driver=virtio-pci`, connector and fb lines. Remaining caveats: `lsmod`,
`dmesg`, `chvt` exist only in the guest (a missing `chvt` does not stop the `printf`, `;`); `basename ""` prints an empty driver.
Can the measurements answer the notify question? Yes, mostly host-side: time from the first GET_DISPLAY_INFO to the next command, and
the display-info re-request after the update, are in `commands.log` and independent of the guest's probe timing; the `/proc/interrupts`
snapshots are secondary (and may not distinguish control/cursor/config vectors if the guest uses one shared line).
Not answered by the run as designed: whether a notification "works" for a guest that never calls the update path; resize.

## Owner decisions (INDEX-Q, the ten) needing attention

1. Name and place: no objection; `ModuleBoundaryTests` keeps the root clean.
2. Main queue for everything: the one that matters. A big transfer, a PNG encode or an endless ring keeps the time limit and the log
   behind it. Acceptable for an owner-run feasibility study with a trusted Debian image; revisit before any hostile-guest use.
3. 2D only: fine; the Linux driver binds by vendor/device id, class 3/0x80 is not needed for binding.
4. Limits: fine for 1280 x 800; the CPU-stall note above is the cost of 16 M-row resources.
5. No network: cloud-init may wait; Q-RUN's 600 s limit absorbs two minutes; note the effect on the config-probe ordering (edit 5).
6. Signing by hand: fine, verified ad hoc + hardened runtime + one entitlement works for `--dry-run`.
7. `.vmr.json` / `.swiftlint.yml` exception: confirmed confined to two lines each, package paths only.
8. Name-only scratch checks: weaker than stated (links, case-insensitive Library, no /tmp confinement); accept or share `vmr guest`'s check.
9. Dates: today is 2026-10-25; the roadmap "Built so far" heading, ADR note and diary file would still say 2026-10-24 when executed.
   Recommend choosing execution-day dating (the card already allows it) so the docs do not carry a false date.
10. No help topic: fine; docs gate passes.

## What only the real-guest run can confirm

Everything about a guest: that it enumerates `1af4:1050`/class `038000` and binds `virtio_gpu`; whether `returnToQueue()` notifies
(and via which vector); whether `update(_:)` raises a config-change interrupt; the exact main-queue callback behaviour of the framework
(that `MainActor.assumeIsolated` in the delegate and the `VZVirtualMachine` callbacks never trap); the exact semantics of
`readBuffersAvailableByteCount`/`writeBuffersAvailableByteCount` for split descriptor chains; whether `guestMemoryMapping` accepts the
page sizes the guest uses; the real transfer cost per row; that a 2D console reaches `scanout.png`; CPU/RSS cost (including the helper
process); whether a stock Debian image has `virtio_gpu`, fbcon and `chvt`; the cloud-init timing relative to the config probe.
