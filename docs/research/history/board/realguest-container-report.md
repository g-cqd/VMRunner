# Real-guest run: container started from the built app (S-RUN)

Run on main `fdebe0c` (detached worktree, debug build), 2026-10-25. "Seen" = observed in this run; "inferred" = reasoned.
Constraints kept: scratch `VMRUNNER_DATA_DIR=/tmp/vmr-s`; app driven only by `vmr control` (explicit `--socket`/`--token-file`) and Accessibility menu clicks on the app's pid; no keystrokes, no mouse, no screenshots, no activation (frontmost app stayed `kitty` before and after); only recorded pids signalled.

## 1. Host and build
- macOS 27.0.1 (26A434), arm64, Mac15,12. HEAD `fdebe0c3b20590f85c2447edda0c505c7077b6ba`. Debug build via `swift run vmr build-app debug` in a detached worktree. Exit 0, wall time 114.5 s (seen).
- Bundle identifier `com.example.VMRunner` (placeholder identifier; same as the owner's app, so the standard defaults domain is shared by name; the run only wrote the `.data-directory-override` domain).
- Embedded runner `Contents/Helpers/ContainerRunner`, 79,348,464 bytes, executable. Build log: `runner: entitlements OK (com.apple.security.virtualization)`, `runner: Signed ...`.
- `codesign --verify --deep --strict --verbose=2` on the app: valid on disk, satisfies Designated Requirement (exit 0).
- Runner entitlements: exactly one key, `com.apple.security.virtualization` = true. Flags `0x10002(adhoc,runtime)` so the runtime flag is present. App entitlements: `device.audio-input` and `virtualization`.

## 2. Setup actually used
- Two machine bundles written as minimal `config.json` (mode 0600, folders 0700): `573D912B-5BBC-42EE-A43B-69B4608681D0.vm` (s-run-quick, command `uname -a; cat /etc/alpine-release`) and `88F88B6D-2B02-42DC-B0B3-1F353829CA39.vm` (s-run-long, same plus `echo long-container-started; sleep 300`). Image `docker.io/library/alpine:3.24.2`, 2 CPUs, 512 MiB, network none, `agentAccess` true, `isProvisioned` true.
- Tolerant decode: seen. Both machines loaded from the minimal JSON; `list --json` showed `"workload":"container"`, `"guest":"linux"`, state `stopped`.
- Defaults key: `com.example.VMRunner.data-directory-override runsControlService = 1`.
- Pre-seeded `Control/tokens.json` (digest scheme as in the card) was accepted at once; the Settings fallback was not needed (seen).

## 3. Timings (seconds, seen)
| Item | Value |
|---|---|
| Build | 114.5 |
| Launch to socket | 0.52 |
| Run 1 (quick, cold) start to running | 63.1 (kernel ~290 MB tarball + image download) |
| Run 1 running to stopped | 0.08 (already stopped at the first poll) |
| Run 2 (quick, warm) start to running | 2.87 |
| Run 2 running to stopped | 0.08 |
| Run 3 (long, cold) start to running | 63.0 |
| Run 3 `stop` answer | 0.07 (`shuttingDown`) |
| Run 3 `stop` to `stopped` | 72.4 (see defects) |
| Run 3b (long, warm) start to running | 8.9 |
| Run 3b `stop --force` answer / runner gone | 0.44 / 0.60 |
| Run 4 start to running | 5.0 |

container-scratch after first start: quick 554 MB (528 MB at the end), long 563 MB (556 MB at the end). Each scratch holds its own copy of the 290,581,648-byte `kata-static-3.17.0-arm64.tar.xz`, `kernel/vmlinux`, `store/` (image, initfs.ext4); two machines = two full downloads/copies (as the card said).

## 4. Run 1 and 2: the quick container
- `start` printed `<id>: running`. A 0.5 s poll showed the runner as the app's only child (pid 90554) until the start returned, i.e. the container ended within about one poll of `running`; `state` was already `stopped` at the first poll after. Final state `stopped`, no child left of the app (seen). Run 2 identical, 2.9 s.
- Log text, `uname -a` containing `aarch64`, the Alpine release line and the exit-status line: NOT SEEN. The app log (stdout/stderr file) holds only the AppKit saved-state line; the log view lives only in the window, and the window is unreachable (section 9). No log is persisted in the machine bundle or exposed by `vmr control`.
- That the guest actually booted and ran the command is inferred (kernel and image downloaded, `running` reached, runner exited, long container stayed up 5+ s and ran for 100+ s).

## 5. Run 3: the long container
- `start` printed `running` after 63.0 s. Runner pid 93813 (child of the app, state SN); its argv shows `--json --image ... --cpus 2 --memory 512 --network none --command ...`. The runner had no child process; the Virtualization framework's guest process `com.apple.Virtualization.VirtualMachine` (pid 94989) is parented to launchd, not the runner (seen). Not present before the run, and gone after each stop.
- Log view text and screenshot: NOT SEEN (no screenshot taken by rule).
- `stop` answered `<id>: shuttingDown` in 0.07 s; state reached `stopped` only after 72.4 s; the runner was gone afterwards, no child of the app. The card expected a prompt stop (stop line, SIGTERM after 10 s grace, SIGKILL 5 s later by the code's `Timing`, so at most about 15 s); 72 s is far longer (defect 1).
- `stop --force` (warm start 8.9 s): answered `stopped` in 0.44 s, runner gone at +0.60 s, no VM process left.

## 6. Run 4: quit with a running container
- Quit via Accessibility: System Events `click menu item "Quit VMRunner"` of menu "VMRunner" in the app's menu bar, by unix id (worked, 0.24 s).
- The app did not exit. 80 s later it was alive and responsive (the control service still answered, container `running`, runner pid 7688 still its child). A new unnamed 260x234 window appeared next to the main window (960x652), positioned like a sheet; inferred: the quit-confirmation alert about the running container (it counts running containers per the card). It could not be confirmed: Accessibility returns no usable window for this process (section 9), and a click or key outside AX is forbidden.
- So the kill-on-quit-through-the-menu question is NOT SEEN. Substituted (card step 6): `kill -TERM` of the app pid 90494 with the container running. The app was gone in 0.27 s and the runner (7688) was gone at 0.30 s, the VM process also gone (seen). Mechanism not determined (SIGTERM handler, or the runner dying when its pipe closes); this is not the same path as the menu quit.

## 7. Descriptors (`lsof -p <app pid> | wc -l`, seen)
At rest 44; after run 1: 46; after run 2: 46; during run 3: 51; after run 3 stop: 54; after the forced stop: 54. Run 1 to 2 shows no further growth; the +8 after run 3 (over rest) persisted after the stop, but the counts include the control socket client connections, window resources and the first window opening in between (I opened the window via the Window menu entry during run 3). Whether this is a leak is NOT determined: the per-kind breakdown was not captured before the app was ended. Treat as a follow-up.

## 8. Processes at the end
No ContainerRunner after run 1, 2, 3 stop, the forced stop, or after the app's SIGTERM. No `com.apple.Virtualization.VirtualMachine` of this run left. (An unrelated Xcode `swift-build` process was visible in the grep; not ours.)

## 9. Errors and surprises
1. Stop to stopped took 72 s (above). Not explained by the code constants; no log to say where time went.
2. The app's windows are not reachable by Accessibility. Launched directly (not by Launch Services) and never activated, the process reports no `AXWindows` (System Events: `windows=0`; the AX API returns the application element for window, main and focused window and an `entire contents` dump never reached content), though `CGWindowList` lists the main window (title `s-run-long`, 960x652, onscreen) once the Window menu entry was pressed. The menu bar was fully readable and clickable. Consequence: the log view, the New Machine sheet and the quit alert cannot be read or pressed without activation; the card's step 5 and its quit-alert click are not doable within the rules. The AX tree walk with `entire contents` can hang (one dump needed a kill; recorded pid 12206).
3. Initially the app opened no window at all (`windows=0`, no CG window), so the log view is not on screen unless a window is requested.
4. No refusal (`-32004`, `-32001`) occurred; every `vmr control` call exited 0.
5. Matches to "read from code": `start` answers `running`; `stop` answers `shuttingDown`; `--force` answers `stopped`; tolerant decode; token digest scheme; the runner is the app's child; the VM process is not.
6. Quit with a running container does not exit the app by itself (a pending alert is inferred, not seen).
7. The bundle identifier is the placeholder `com.example.VMRunner`, shared by name with the owner's standard defaults domain. The owner's `~/Library/Preferences/com.example.VMRunner.plist` is unchanged (2702 bytes, mtime 1792895605 before and after; `defaults read` of the standard domain identical before and after).
8. The app wrote an empty `$TMPDIR/com.example.VMRunner.savedState` folder (removed).

## 10. Cleaned and left
Removed (see final check below): worktree `VMRunner-chains/s-run-wt` (with its build output and `.build`), `/tmp/vmr-s`, `/tmp/vmr-s-run`, the defaults domain `com.example.VMRunner.data-directory-override`, `$TMPDIR/com.example.VMRunner.savedState`. Kernel/image caches were inside the removed scratch folders. A `CFNetworkDownload_Xh9nXD.tmp` in `$TMPDIR` existed before the run and is unchanged (not mine, left). The main checkout's `build/` and `.build*` were not touched. Only the recorded pids 90494 (app), 93813, 7173, 7688 (runners) and 12206 (my hung dump) were signalled or involved.

## 11. Verdict
1. Build-app yields a bundle whose embedded runner verifies with exactly one entitlement: YES (seen).
2. App starts a container from the control service, reaches `running`, ends `stopped` with no runner left: YES for start, state and process (seen). Showing the container's output in the app: NOT SEEN (window unreachable).
3. Costs: cold ~63 s (downloads, ~290 MB per machine), warm 2.9 s (quick) and 5 to 9 s (long): YES (seen).
4. Stop line works and a stopped container leaves no runner: YES, but slow (72 s); forced stop immediate (0.6 s): YES. Kill on quit through the menu: NOT SEEN (alert pending, unreachable). SIGTERM of the app with a running container leaves no runner and no VM process: YES (seen, different path).
5. Descriptor leak across runs: NOT DETERMINED (44 to 46 after runs 1 and 2 and flat between them; 54 after run 3; no breakdown).

## Final cleanup check (seen)
Worktree removed, `/tmp/vmr-s*` gone, no ContainerRunner process, owner plist unchanged (2702 bytes, same mtime). Left: the defaults domain `com.example.VMRunner.data-directory-override` still reads as an empty `{ }` after `defaults delete` (the system wrote it back); `VMRunner-chains/` kept because it holds a pre-existing `.DS_Store`; the pre-existing `CFNetworkDownload_Xh9nXD.tmp`.
