#!/usr/bin/env python3
"""The VMRunner work board: board.json is the source, status.js is what index.html polls.

  board.py init                      create board.json from the seed (only if absent)
  board.py set ID STATUS [NOTE...]   set a step's status (todo running done owner verify deferred) and a note
  board.py note ID NOTE...           add a note without changing the status
  board.py list [STATUS]             print steps
"""
import json, sys, time, os
HERE = os.path.dirname(os.path.abspath(__file__))
BOARD = os.path.join(HERE, "board.json")
OUT = os.path.join(HERE, "status.js")
STATUSES = ["todo", "running", "done", "owner", "verify", "deferred"]

PHASES = [
    ("owner", "Needs you", "Things only you can do or confirm: real guests, certificates, reviews and decisions."),
    ("flight", "In flight", "Work an agent is doing right now."),
    ("B", "B. Test support (roadmap 0031)", "Sync the improved test utilities and use them."),
    ("C", "C. Names and packages (roadmap 0032)", "One naming convention, then local Swift packages."),
    ("D", "D. Performance and memory (roadmap 0033)", "Small, gated by the benchmark step."),
    ("E", "E. Contributions to aemi (roadmap 0035)", "Reusable parts shipped as patches for review."),
    ("F", "F. Security backlog (roadmap 0034)", "Open findings from the adversarial reviews."),
    ("G", "G. Roadmap features", "In dependency order."),
    ("H", "H. Housekeeping", "Docs, diary and cleanup."),
    ("U", "Follow-ups reported by agents", "Smaller items found while fixing the above."),
    ("done", "Done this session", "Merged, signed, gate green. Kept for reference."),
]

# (id, phase, title, what, [how to check], roadmap, status)
S = []
def add(i, ph, title, what, check=(), rm="", st="todo"): S.append(dict(id=i, phase=ph, title=title, what=what, check=list(check), roadmap=rm, status=st, note="", updated=""))

# ---- needs you
add("O1","owner","Run the real-guest checklist","17 rows covering Filtered mode, DHCP and DNS, allow and deny rules, live edit, flow log, VPN indicator, path change, throughput, suspend and resume, NAT, display, snapshots. One macOS and one Linux guest.",
    ["Open docs/roadmap/0030-real-guest-validation.md","Run each row on a macOS guest, then a Linux guest","Reply with pass, fail or skip per row and what you saw for a fail"],"0030","owner")
add("O2","owner","Measure input latency (macOS and Linux guests)","The monitor and the latency-critical activity are merged. I need numbers to attribute the delay to a stage.",
    ["swift run vmr build-app","open -n build/VMRunner.app --args --input-latency --input-latency-file ~/Desktop/latency-RUN1.txt","Type and move the mouse for a minute, quit, repeat per run: macOS and Linux guest, NAT and Filtered, Trackpad and Mouse","Send me the files; the full protocol is docs/research/input-latency-2026-10.md"],"0037","verify")
add("O3","owner","Is the Linux boot text legible now?","The starting size for a Linux guest is capped at 1280 wide on every path, and the firmware is left alone for 10 s.",
    ["New Linux machine, default settings, start the installer","Look at the firmware screen, the GRUB menu and the first console","If still tiny: start with --display-diagnostics and send the scanout size in config.json, window size and backing scale (Settings help: Small text at boot)"],"0038","verify")
add("O4","owner","Window resizing and full screen","A new follower retries refused resizes and ignores bursts; the view no longer rewrites its properties on every update.",
    ["On a macOS guest and a Linux guest: drag-resize, maximise, full screen in and out, move to an external display","Check: picture stays aligned, scaled to the window and centred, no stale or corrupted area","If not: start with --display-diagnostics and send the log"],"0039","verify")
add("O5","owner","Pause, shut down, force stop and the other transitions","The state is now one explicit machine; the toolbar shows Pausing, Shutting down, Stopping and a Paused overlay.",
    ["Start, Pause (expect Resume button and a dimmed Paused overlay), Resume","Shut Down (expect Shutting down, then stopped, or use Force Stop if the guest ignores it)","Suspend and restore, disposable discard, quit while running, rapid repeated clicks","Tell me which guest you used"],"0040","verify")
add("O6","owner","Install Alpine (signature fallback)","Alpine published 3.24.3 without a signature; the app now takes the newest signed release and says so.",
    ["New Machine, choose Alpine Linux","Expect the notice 'Alpine Linux 3.24.3 has no signature yet; using 3.24.2.' and a normal download"],"0034","verify")
add("O7","owner","Container first run","Pulls alpine through Apple's containerization package and runs uname.",
    ["swift run vmr container-sign",".build-packages/Packages-Containers/release/ContainerRunner ~/ContainerRunnerScratch","Same with --network loopback","Report per docs/research/containers-2026-10.md, First run"],"0024","owner")
add("O8","owner","Sandbox boot run","Boots a Linux guest from a helper under Seatbelt and App Sandbox.",
    ["Follow 'The owner's boot run' in docs/research/sandboxing-2026-10.md (five commands)","Paste back the reports"],"0025","owner")
add("O9","owner","Review the aemi Base64 patch","Configurable Base64 (alphabet, padding, trailing bits, whitespace, line length, typed errors); .strict preset for armor; lenient stays the default.",
    ["cd ~/Developer/g-cqd/aemi-wt-base64 && git log --oneline main..base64-configurable","Patch series: ~/Developer/g-cqd/aemi-patches/base64/","Tell me to merge it, change it, or drop it"],"0035","owner")
add("O10","owner","Review the aemi test-utility upgrade","Unified probes, clock parity, allocation window, benchmark recorder, task provider spy. Macros 15 floor kept.",
    ["Appears here when the agent finishes: ~/Developer/g-cqd/aemi-wt-testsupport","Patches and VMRUNNER-SYNC.md in ~/Developer/g-cqd/aemi-patches/test-support/"],"0035","todo")
add("O11","owner","Tag the two private-API packages","Needed before I add the interop dependency and the PrivateInterfaces module.",["Tag both packages and tell me the tags"],"0029","owner")
add("O12","owner","Developer ID certificate and entitlement test","Does com.apple.security.virtualization work under Developer ID?",["Provide the certificate/identity name","Run the signed build and start a VM"],"0021","owner")
add("O13","owner","Publication: placeholders, push, ruleset","Fill @OWNER and the bundle identifier, push, apply the ruleset; run actionlint and zizmor.",["See CONTRIBUTING: Publication checklist"],"0027","owner")
add("O14","owner","Decide ADR status","ADR-0012, 0013, 0016, 0017 and 0019 are still proposed.",["Tell me which to accept, change or supersede"],"","owner")
add("O15","owner","Check the bundle has no get-task-allow","The latency work found it worth checking on your actual bundle.",["codesign -d --entitlements - build/VMRunner.app","Expect only virtualization and audio-input (plus hardened keys if --hardened)"],"0037","verify")
add("O16","owner","Decide: sync the vendored TestKit or pin aemi","aemi becomes the source of truth for the test utilities.",["Pick: keep a vendored copy synced from aemi (recommended, ADR-0001) or add an exact pin"],"0035","owner")
add("O17","owner","macOS 27 host (GPU, Secure Boot)","Linux GPU and custom virtio-gpu need macOS 27; this host is 26.7.1.",["Tell me when you have one"],"0014","deferred")
# ---- in flight
add("F1","flight","aemi test-utility upgrade","Reproduce the ten suspected defects, unify AsyncEventProbe/CountProbe, clock parity, allocation window, benchmark recorder, task provider spy, ThreadGate; macOS 15 floor; patches and a sync note.",
    ["Agent report arrives here; then O10"],"0035","running")
# ---- B
add("B1","B","Sync the vendored TestKit from aemi","Apply VMRUNNER-SYNC.md once the aemi branch is merged.",["vmr check green; TestKitTests pass"],"0031")
add("B2","B","Task provider seam in Debouncer, RuntimeLimit, ConfigPersistence, VPNMonitor, VMLibrary, NetworkActivity","Replace raw Task {} so tests can see and settle tasks.",["No Task.yield() loops left in those tests"],"0031")
add("B3","B","Remove yield loops and 1 ms polling in tests","NetworkActivityTests polls with a real sleep; others loop on Task.yield().",["Suites pass 100 consecutive runs"],"0031")
add("B4","B","Tests for the probe, clock and process probe; ported facilities","Deallocation probe, observed-state wait, manual-completion double, scoped URL stub.",["Each facility has a test that fails without it"],"0031")
# ---- C
add("C1","C","Naming ADR","No planning words, no Kit/Util/Helper/Manager suffix, <Executable>Core, no module named like a framework or its main type.",["vmr check docs green"],"0032")
add("C2","C","Rename TestKit to TestSupport (and CTestKitMalloc)","Mechanical rename after the branches importing it merged.",["Gate green; no TestKit left"],"0032")
add("C3","C","Seams inside the app","VPN pieces together, policy gate with the policy, virtualization glue out of the stack, split Downloads.swift, Checksum out of VMConfig, MachineStore protocol, injected logger.",["No behaviour change; gate green"],"0032")
add("C4","C","Teach vmr about packages","Shared settings block sync/check, sanitizers, coverage, bench, analyzers, lint, CI cache keys loop over packages.",["Fixture tests for each step"],"0032")
add("C5","C","Extract TestSupport package","",["Gate green"],"0032")
add("C6","C","Extract NetPolicy","Policy, rules, host and IP parsing.",["vmr check bench unchanged"],"0032")
add("C7","C","Extract NetStack","The user-mode stack. Never split wire parsers from the core.",["Per-packet allocation baselines and 3% instruction budget unchanged"],"0032")
add("C8","C","Extract ImageTrust","OpenPGP, checksums, download policy, catalogs.",["Gate green"],"0032")
add("C9","C","Optional: Tooling package","DevTools and vmr.",[],"0032","deferred")
# ---- D
add("D1","D","One reusable read buffer for hashing","App and tooling, one chunk size.",["checksum instructions-per-MiB gate not worse"],"0033")
add("D2","D","One hex helper; digest loops over HashFunction","",["bench not worse"],"0033")
add("D3","D","Table-driven CRC-24","Only while touching that file.",[],"0033")
add("D4","D","Profile the Regex listing parsers","Replace only if measurable.",[],"0033")
# ---- E
add("E1","E","Allocation window and benchmark recorder into aemi","Part of the running upgrade.",[],"0035","running")
add("E2","E","Packet parsers, checksum arithmetic and rings into aemi","After the stack package exists.",[],"0035")
add("E3","E","Debounce and poll helpers into aemi","",[],"0035")
# ---- F
add("F2","F","Alpine and Secure Boot","Isolated/Hardened turn Secure Boot on; Alpine cannot boot with it. supportsSecureBoot is never read.",["A test: Alpine + Hardened does not enable Secure Boot, and the UI says why"],"0034")
add("F3","F","Alma, Rocky and every Fedora release","Host entries and pinned keys (verify fingerprints on two vendor pages).",[],"0034")
add("F4","F","Debian netboot signed chain","Archive Release file chain and keys.",[],"0034")
add("F5","F","Key expiry dates on pinned keys","Re-check at each release.",[],"0034")
add("F6","F","Domain deny rules lapse with the name table","Derived address blocks.",[],"0034")
add("F7","F","DNS worker pool; byte-bounded guest transmit queue; floor opt-in","",[],"0034")
add("F8","F","DNS-over-TCP answer dropped silently when the ring is full; answered DNS events not folded","",[],"0034")
add("F9","F","Bounds: snapshot.json, config free text, absolute ImageSource.local","",[],"0034")
add("F10","F","Delete the sha1 enum case; migrate old flat-cache machines; clone the restore image","",[],"0034")
add("F11","F","Coverage-guided fuzz target","Signature, DNS and packet parsers.",[],"0034")
add("F12","F","Run actionlint and zizmor; CI on GitHub","Never run so far.",[],"0034")
add("F13","F","Find the cause of the GateLock flake; watch the TSan abort","A retry hides the first; the second did not reproduce.",[],"0034")
add("F14","F","Bench job required in CI","After stable hosted-runner figures.",[],"0034","deferred")
add("F15","F","Nested package in analyzer roots; cache .build-packages; licence inventory","",[],"0034")
# ---- G
add("G1","G","Workload abstraction","Protocol and capability flags between library, controller and views; after the container and sandbox runs.",[],"0024")
add("G2","G","Managed preferences (0013)","",[],"0013")
add("G3","G","Automation server (0005)","Awaitable start/suspend, socket then MCP, tokens, screenshots, serial, vsock, recording.",[],"0005")
add("G4","G","Host information sharing (0011)","",[],"0011")
add("G5","G","Realism knobs (0012)","",[],"0012")
add("G6","G","Guest VPN probe, kill switch, metered guard (0010)","",[],"0010")
add("G7","G","Provisioning (0016)","",[],"0016")
add("G8","G","Developer ID and notarization (0021)","Needs your certificate.",[],"0021")
add("G9","G","PrivateInterfaces (0029)","Needs your package tags.",[],"0029","owner")
add("G10","G","Container networking through the user-mode stack; macOS OCI store (0024)","",[],"0024","deferred")
add("G11","G","Sandbox engine and level settings; real guest network in the helper (0025)","",[],"0025")
# ---- H
add("H1","H","Fix stale documents","README CentOS-specific; ADR-0018 SwiftLint from Homebrew; ADR-0009 lock undecided; ADR-0017 nothing built; ADR-0021 signatures; roadmap 0019 owed list.",["vmr check docs green"],"")
add("H2","H","Update the session diary entry","Latency, display, state machine, downloads, Alpine, renames, claims and verdicts.",[],"")
add("H3","H","Update roadmap 0036 to what has landed","",[],"0036")
add("H4","H","Final cleanup","Remove aemi worktrees after your review, delete /tmp scratch, check git worktree list and background processes.",[],"")
# ---- U
add("U1","U","Write the suspend image under a temporary name and rename","A crash mid-suspend can leave a partial file.",[],"0040")
add("U2","U","Make VMLibrary.load() idempotent; --start skips unprovisioned machines silently","",[],"0040")
add("U3","U","EFI variable store may hold an early large mode","Test whether it overrides the cap.",[],"0038")
add("U4","U","Full screen swaps in a fresh view each time","Possible source of corruption.",[],"0039")
add("U5","U","Latency follow-ups","Set view properties only on change; NSEvent mouse coalescing; build and ephemeral clone off the main actor; ConfigPersistence flush off the main thread.",[],"0037")
add("U6","U","vmr analyzers versions lists only three analyzers","",[],"0021")
# ---- done
for i,t,w,rm in [
 ("d1","Housekeeping, flaky VPN test fixed","The flake was a real bug: a snapshot queued at stop() could overwrite unknown. 30 of 30 failed without the fix.","0019"),
 ("d2","Real-guest checklist written","","0030"),
 ("d3","Pinned SwiftLint","Checksum-verified release in the lock, like the analyzers.","0021"),
 ("d4","Allocation and benchmark gate","vmr check bench; instructions and allocations enforced, rates report-only.","0018"),
 ("d5","Performance leftovers","Runtime limit, debounce, poll on an injected clock; help index precomputed.","0019"),
 ("d6","Alpine and Ubuntu providers","","0022"),
 ("d7","OpenPGP verifier","Strict v4 RSA, pinned vendor keys, fail closed, fuzzed; independent review done.","0023"),
 ("d8","Sandbox helper (no guest booted)","vmr sandbox, Seatbelt and App Sandbox engines.","0025"),
 ("d9","Container runner as its own package","containerization 0.52.1; root package unchanged.","0024"),
 ("d10","Adversarial reviews and fixes","Tooling, configuration, network, downloads findings fixed with regression tests.","0034"),
 ("d11","Worktree cleanup practice","","")  ,
 ("d12","Persisted plan: roadmap 0031-0040 and studies","","0036"),
 ("d13","Cryptography study","","")  ,
 ("d14","Input latency monitor and activity assertion","Opt-in monitor, latency-critical activity, batched flow log.","0037"),
 ("d15","Linux starting display capped and follower rewritten","","0038"),
 ("d16","Machine state machine","","0040"),
 ("d17","Alpine signature fallback","","0034"),
 ("d18","Sandbox, container and helper renames","vmr sandbox, ContainerRunner, VMHelperCore.","0032"),
 ("d19","aemi Base64 patch prepared","Awaiting your review (O9).","0035"),
]:
    add(i,"done",t,w,[],rm,"done")

def load():
    with open(BOARD) as f: return json.load(f)
def save(d):
    d["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(BOARD, "w") as f: json.dump(d, f, indent=1)
    with open(OUT + ".tmp", "w") as f:
        f.write("window.BOARD = " + json.dumps(d) + ";\n")
    os.replace(OUT + ".tmp", OUT)

def main(a):
    if not a: print(__doc__); return
    if a[0] == "init":
        if not os.path.exists(BOARD) or "--force" in a:
            save(dict(phases=[dict(id=i, title=t, intro=n) for i,t,n in PHASES], steps=S))
        else: save(load())
    elif a[0] in ("set", "note"):
        d = load(); sid = a[1]; hit = [s for s in d["steps"] if s["id"] == sid]
        if not hit: sys.exit("no step " + sid)
        s = hit[0]
        if a[0] == "set":
            if a[2] not in STATUSES: sys.exit("status must be one of " + " ".join(STATUSES))
            s["status"] = a[2]; note = " ".join(a[3:])
        else: note = " ".join(a[2:])
        if note: s["note"] = note
        s["updated"] = time.strftime("%H:%M:%S"); save(d)
    elif a[0] == "list":
        d = load()
        for s in d["steps"]:
            if len(a) < 2 or s["status"] == a[1]: print(s["status"].ljust(8), s["id"].ljust(5), s["title"])
main(sys.argv[1:])
