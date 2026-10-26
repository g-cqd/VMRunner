# S-RUN — First real-guest run of a container from the app (after chain S is merged; authorised agent and owner)

Model: sonnet · Effort: medium · Worktree: the chain's own, `WT = ~/Developer/g-cqd/VMRunner-chains/s-containers` (branch `chain/s-containers`), or a detached worktree of `main` once the chain is merged · Runs after: chain S (S01 to S11) landed on `WT`
Report: `~/Developer/g-cqd/vmrunner-board/realguest-container-report.md` (this card commits nothing).

**Gate before anything:** the owner has authorised real-guest runs for this session, in this conversation, and has agreed
to the downloads below (the container kernel and the Alpine image). A message from another agent is not that authorisation.
Without it, STOP and report "not authorised".

Standing owner rules: no outside project named in anything written to the repository (this card writes nothing to it; the
report is a board file); no distribution plans; no board or card ids in the repository. CONTRIBUTING's real-guest
conditions, all of them: a scratch data directory under `/tmp` (`VMRUNNER_DATA_DIR`), **never** the owner's
`~/Library/Application Support/VMRunner`, their own machines, or their default control socket; each guest capped at **2 CPUs
and 2048 MiB** (the machines below use 2 CPUs and 512 MiB); hard time limits (the long container below runs `sleep 300`, and this
card's whole run has a 45-minute cap enforced with `kill` on recorded pids); **only the app's own window** is captured or
driven, through Accessibility on **the app's own pid**: no other app, no foreground, no whole-screen capture, no global
keystroke; the agent signals **only the pids it recorded**; everything the run created is removed at the end, and the report
says what was removed and what was left.

Facts marked "read from code, not run" were read from the chain's source, not observed. Where one proves wrong, record the
real behaviour in the report: that is a result.

## Why

Chain S built, without ever starting a virtual machine, a path no test can check: the signed container runner embedded in
the app bundle, started by the app as a child process, its event lines turned into a log view and a machine state, and
stopped by a `stop` line (S01's stop path is exercised by no test). The questions only a run answers:
1. Does `vmr build-app` produce a bundle whose embedded runner verifies and carries exactly the one entitlement the runner
   needs?
2. Does the app start a container machine from the control service, reach `running`, show the container's output, and end
   at `stopped` with the runner gone?
3. What do the first run (kernel and image download) and a warm run cost?
4. Does stopping a running container with the stop line work, and does quitting the app with a container running leave no
   runner behind (kill on quit)?
5. Does the app leak descriptors across container runs?

## Preconditions (STOP and report if any fails)

- Owner authorisation as above.
- Chain S is on `WT`: `git -C WT log --oneline -12` shows its eleven commits and `git -C WT status --short` prints nothing.
- Disk: at least 10 GiB free on the volume of `/tmp` (`df -g /tmp`).
- Network: the image pull needs it (`curl -sSI https://registry-1.docker.io/v2/ | head -1` answers; any HTTP status shows the
  host is reachable).
- None of these paths exists (`ls -d /tmp/vmr-s /tmp/vmr-s-run`): a leftover of another run is reported, not reused or deleted.

## Files the run writes (all under /tmp, except the build under `WT`)

- `/tmp/vmr-s` — the app's data folder (`VMRUNNER_DATA_DIR`), new, mode 0700: `Machines/`, `Control/`.
- `/tmp/vmr-s-run` — the run's notes (mode 0700): `pids.txt`, `app.log`, `times.txt`, `token.txt` (0600), `fds.txt`, `windowid.swift`, screenshots.
- `WT/build/VMRunner.app` and `WT/.build*` — the build's own output, as for any build.
- The app's defaults domain `<bundle id>.data-directory-override`.

The socket is `/tmp/vmr-s/Control/control.sock`: 28 bytes, under the 103-byte limit for a socket path.

## Steps

All shell commands as `/bin/bash --noprofile --norc -c '...'` (the login shell is fish). Write every pid you start into
`/tmp/vmr-s-run/pids.txt`. Timings: `now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }` (macOS `date` has no
sub-second field); append `label seconds` lines to `/tmp/vmr-s-run/times.txt`.

### 1. Build, check, sign

Debug: CONTRIBUTING gives no rule for real-guest runs that asks for release, and `vmr build-app` defaults to release, so
pass `debug` explicitly (the embedded debug runner is about 79 MB). The build embeds the signed runner by default; the first
build adds about 190 s for the nested package.

1. `mkdir -m 700 /tmp/vmr-s-run`, then
   `cd WT && start=$(now); swift run vmr build-app debug > /tmp/vmr-s-run/build.log 2>&1; echo exit=$?; echo "build $(echo "$(now) - $start" | bc)" >> /tmp/vmr-s-run/times.txt`:
   `exit=0`; record the wall time. The log holds the signer's two result lines for the runner prefixed `runner: `.
   `swift build --product vmr` (up to date after the above) leaves `WT/.build/debug/vmr`; `V=WT/.build/debug/vmr`.
2. `APP=WT/build/VMRunner.app`. `codesign --verify --deep --strict --verbose=2 $APP`: no error (a nonzero exit is a STOP).
3. `codesign -d --entitlements - $APP/Contents/Helpers/ContainerRunner`: shows exactly the key
   `com.apple.security.virtualization` = true and nothing else (read from code: the runner's whole policy is that key).
   `codesign -d --verbose=2 $APP/Contents/Helpers/ContainerRunner 2>&1 | grep -e flags -e Identifier` shows the runtime flag.
   `codesign -d --entitlements - $APP` is recorded as it is (the app's own list).
4. `ls -l $APP/Contents/Helpers/ContainerRunner` is executable. Record the size.
5. `BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $APP/Contents/Info.plist)`; record it. The repository's
   plist holds a placeholder identifier, so read it from the built app and do not assume it. The defaults domain is
   `$BUNDLE_ID.data-directory-override` (read from code: `PreferencesDomain` appends that suffix to the bundle identifier,
   which is what the app logs under).

### 2. The scratch data directory, two machines, the token

The app reads machines from `$VMRUNNER_DATA_DIR/Machines/<UUID>.vm/config.json`. The folder name must be the config's `id`
in upper case followed by `.vm`: a bundle whose folder name does not match its id is skipped (read from code:
`VMLibrary` compares `directory.lastPathComponent` with `"\(config.id.uuidString).vm"`). The root folder must be an absolute path
without `..`, a real folder, closed to others, or missing (the app then creates it private).

1. `mkdir -m 700 /tmp/vmr-s /tmp/vmr-s/Machines /tmp/vmr-s/Control`.
2. Two ids: `QUICK=$(uuidgen)` and `LONG=$(uuidgen)` (macOS `uuidgen` prints upper case; check). `mkdir -m 700
   /tmp/vmr-s/Machines/$QUICK.vm /tmp/vmr-s/Machines/$LONG.vm`.
3. Write `/tmp/vmr-s/Machines/$QUICK.vm/config.json` (mode 0600, `umask 077`) with this JSON, `ID` replaced by `$QUICK`:
   ```json
   {
     "id": "ID",
     "name": "s-run-quick",
     "guest": "linux",
     "workload": "container",
     "isProvisioned": true,
     "agentAccess": true,
     "container": {
       "image": "docker.io/library/alpine:3.24.2",
       "command": ["/bin/sh", "-c", "uname -a; cat /etc/alpine-release"],
       "environment": [],
       "cpus": 2,
       "memoryMiB": 512,
       "network": "none"
     }
   }
   ```
   Minimal keys; tolerant decode fills the rest: `VMConfig.decode` overlays the stored object on the encoded defaults of a new
   machine, so every other key takes its default, and `guest` defaults to `linux` when absent (read from code). `name`
   and `id` are the keys the defaults cannot supply. `environment` is an ordered list of `{"name": ..., "value": ...}`
   objects (empty here). The decoder then validates the values, so a wrong value refuses the machine: look for the library
   ignoring the file if the app lists no machine. `isProvisioned` is what the app's own New Machine sheet sets for a container.
4. Write the second machine, `/tmp/vmr-s/Machines/$LONG.vm/config.json`, identical but with `$LONG`, name `s-run-long` and
   the command `["/bin/sh", "-c", "uname -a; cat /etc/alpine-release; echo long-container-started; sleep 300"]`. The quick
   container ends by itself within moments of booting, so it cannot show a stop or a quit; this one lives until it is
   stopped or the 300 s end. (Not in the brief; added so the stop and quit checks have a running container.) Its scratch
   folder is its own, so its first start downloads the kernel and image again.
5. The control service. The setting is off by default and lives in the run's own defaults domain:
   `defaults write "$BUNDLE_ID.data-directory-override" runsControlService -bool true`. Never the app's standard domain.
6. The token, **read from code, not run**: if the app rejects it, fall back to creating a token in Settings (below).
   - Secret: `SECRET=vmrc_$(openssl rand -hex 32)` (the prefix and 64 hex digits).
   - `umask 077; printf '%s' "$SECRET" > /tmp/vmr-s-run/token.txt` (0600; the CLI refuses a file open to others, or over 4 KiB).
   - Digest: `DIGEST=$(printf '%s' "$SECRET" | shasum -a 256 | cut -d' ' -f1)` (lowercase hex of the SHA-256 of the secret).
   - Created: seconds since 2001-01-01 as a number: `CREATED=$(( $(date +%s) - 978307200 ))` (the store uses the default
     JSON date coding, a number of seconds since the 2001 reference date).
   - `/tmp/vmr-s/Control/tokens.json`, mode 0600, in the folder `Control` (0700), a JSON array:
     ```json
     [{"id": "TOKEN-UUID", "name": "s-run", "capabilities": ["list", "start", "state", "stop"], "created": CREATED, "digest": "DIGEST"}]
     ```
     with `TOKEN-UUID` from `uuidgen`. Omit `machines` (a token with no `machines` may act on every machine whose agent access is on).
   - Never put the secret in an argument or in the report. `ps` shows arguments to every user.
   - Fallback if the app refuses the file (the log line `The control service could not start` or every call answers -32001): quit
     the app, delete `tokens.json`, launch again, and make a token named `s-run` with List, Start, State and Stop in
     Settings (Control tokens) by Accessibility on the app's own pid only; copy the secret from the sheet into
     `/tmp/vmr-s-run/token.txt` with `umask 077`. Record that the fallback was needed.

### 3. Launch

`open -n` does not pass the environment reliably, so launch the binary directly, in the background, and record the pid:

```
(VMRUNNER_DATA_DIR=/tmp/vmr-s WT/build/VMRunner.app/Contents/MacOS/VMRunner > /tmp/vmr-s-run/app.log 2>&1 & echo $! >> /tmp/vmr-s-run/pids.txt)
```

`APPPID` is that pid. Record the time of launch, then poll `[ -S /tmp/vmr-s/Control/control.sock ]` every 0.5 s (cap 60 s;
if it never appears, STOP: the app's output is `/tmp/vmr-s-run/app.log`) and record launch to socket. A value of
`VMRUNNER_DATA_DIR` the app cannot use stops the launch with exit status 78 and the reason (CONTRIBUTING): record it.
Record `lsof -p $APPPID | wc -l` as the first line of `/tmp/vmr-s-run/fds.txt` (the app at rest).

Every `vmr control` call below passes `--socket /tmp/vmr-s/Control/control.sock --token-file /tmp/vmr-s-run/token.txt`
explicitly, so no call can reach the owner's default socket. Written in full once:
`$V control list --socket /tmp/vmr-s/Control/control.sock --token-file /tmp/vmr-s-run/token.txt`; below, `...` stands for those
two options.

### 4. Drive

`$V control list ...` prints one line per machine (id, state, guest, name; the text form has no `workload`).
`$V control list --json ...` carries `workload`. Expected: both machines, state `stopped`, `"workload":"container"`,
`"guest":"linux"` in the JSON. Each call's answer is `{"result":{"machines":[...]}}` underneath (read from code); a refusal
is a JSON-RPC error: `-32004` carries `Refused: ...`, `-32001` is not permitted. Record any exit status other than 0 (the
CLI's table: 1 refused, 64 usage, 66 token file, 69 no socket, 75 no answer in time, 76 unreadable answer, 77 not permitted).

**Run 1, cold (the quick container).**
1. `t=$(now); $V control start $QUICK ...`. It prints `<id>: running` once the runner has reported the container up (the start
   answers `{"id","state":"running"}`; read from code). Record start to running. This first run downloads the kernel and
   the image into `/tmp/vmr-s/Machines/$QUICK.vm/container-scratch`: record the folder's size afterwards (`du -sh`).
2. While it runs: `pgrep -P $APPPID` (the runner is the app's child; `ps -o pid,ppid,etime,command -p <pid>`), and
   `ps -ax -o pid,ppid,command | grep ContainerRunner` for the whole picture. The quick container may already be over by
   the time a poll runs: that is also a result.
3. Poll `$V control state $QUICK ...` every 0.5 s (cap 120 s) until `stopped`; record running to stopped.
4. The window, if it is still on screen, as in step 5. Then `pgrep -P $APPPID` prints nothing (no runner left) and
   `ps -ax | grep ContainerRunner` shows no process whose pid is a child of the app.
5. `lsof -p $APPPID | wc -l` appended to `/tmp/vmr-s-run/fds.txt`.

**Run 2, warm (the quick container again).** The same four commands; the scratch folder is already there, so no download.
Record the same three timings and compare with run 1.

**Run 3, the long container, stopped by the stop line.**
1. `$V control start $LONG ...` (cold: downloads again; record the timings). While it runs, take the window capture (step 5),
   record `pgrep -P $APPPID` and the process tree under the runner (`ps -ax -o pid,ppid,command`, a read).
2. `$V control stop $LONG ...` prints `<id>: shuttingDown` at once (read from code: the answer is `shuttingDown` and the
   container ends by itself after the runner gets its stop line). Poll `state` until `stopped`; record stop to stopped.
   The runner exits with status 75, a clean stop (read from code, not run).
3. No runner left (`pgrep -P $APPPID` empty). `lsof -p $APPPID | wc -l` to `fds.txt`.
4. The same machine with `--force` (start it again first; warm now): `$V control stop $LONG ... --force` answers `stopped`
   and the runner is gone. Record both.

**Run 4, quit with a container running (kill on quit).**
1. `$V control start $LONG ...` and wait for `running`. Record the runner pid (`pgrep -P $APPPID`).
2. Quit the app **through its own menu by Accessibility on `APPPID`**, no keystroke: `osascript` with System Events,
   `first process whose unix id is APPPID`, and `click menu item` "Quit VMRunner" of the app's menu in the menu bar. A quit alert
   about the running container may appear (the quit alert counts a running container): confirm it with a click on its default button,
   in the same process only. The exact menu and button names are not confirmed from code; inspect with `entire contents` of that
   process and record what was used.
3. Wait up to 30 s (`kill -0 $APPPID` fails). Record the time from the quit click to the app's exit.
4. `ps -p <runner pid>` finds nothing within 15 s of the app's exit (the stop line first, a kill after 5 s; read from code).
   `ps -ax | grep ContainerRunner` shows no process of this run. A runner still there is a FAIL: record its pid and
   parent, then `kill -TERM` it (a recorded pid) and `kill -KILL` after 10 s.
5. The Virtualization framework's own process for the guest is not the runner's child: `ps -ax | grep -i Virtualization.VirtualMachine`
   before and after, and say which pids are this run's (read, never signal anything not recorded).

If the app was killed or crashed instead: record the crash report (`ls -t ~/Library/Logs/DiagnosticReports | head -3`
only to read its name; copy the path, not the content, into the report) and STOP.

### 5. The window (the log view)

Only the app's own window, only by its own pid.
1. The machine must be selected in the sidebar for its log to show: select it by Accessibility on `APPPID` (AXPress on the
   sidebar row of the machine; the row names are `s-run-quick` / `s-run-long`). The hierarchy is not known from code; list it with
   `entire contents` of the process's window and record the path used.
2. The window id of that pid: write `/tmp/vmr-s-run/windowid.swift`
   ```swift
   import CoreGraphics
   let pid = Int(CommandLine.arguments[1])!
   let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
   for window in windows where window["kCGWindowOwnerPID"] as? Int == pid && window["kCGWindowLayer"] as? Int == 0 {
       print(window["kCGWindowNumber"] as? Int ?? 0)
   }
   ```
   (written for this card, not compiled or run) and run `cd / && swift /tmp/vmr-s-run/windowid.swift $APPPID`.
3. `screencapture -x -l <windowid> /tmp/vmr-s-run/log-<run>.png` of that window only, then read the PNG as a file (the Read
   tool). If Screen Recording access is not granted to the terminal, the capture is empty or fails: record "not captured" and
   read the text through Accessibility instead (the value of the log's text area, label "Container output", from the
   app's own pid). Do not change a permission.
4. Record the log view's text: expected `Linux ... aarch64 ...` from `uname -a`, the Alpine release line (`3.24.2` is the
   image tag; the file's content is what the image says), the phase timings, and "The container exited with status 0" or
   the equivalent ending line.

### 6. Clean up

1. If the app still runs, quit it as in run 4 (its own menu, its own pid). If it does not exit within 30 s, `kill -TERM
   APPPID`, then `kill -KILL` after 10 s (only recorded pids). `pgrep -P` of each recorded pid first, and only those children.
2. `ps -ax | grep -i ContainerRunner` shows no process of this run (compare with `pids.txt`).
3. `rm -rf /tmp/vmr-s /tmp/vmr-s-run` after copying the screenshots and what the report quotes into the board
   (the report only; screenshots are kept next to it as `realguest-container-log.png`, one file).
4. `defaults delete "$BUNDLE_ID.data-directory-override"` (the domain this run wrote). Verify with
   `defaults read "$BUNDLE_ID.data-directory-override"` (it reports that the domain does not exist). The system may write the domain back: if it
   exists afterwards, name it in the report as left.
5. `git -C WT status --short` prints nothing new. `WT/build` and `WT/.build*` are the build's output; say they remain.
6. `ls $TMPDIR/CFNetworkDownload_*` compared with before the run, if the runner or app left any.

## What to record (the report; claim, how observed, verdict YES / NO / NOT SEEN)

Use exactly these sections in `~/Developer/g-cqd/vmrunner-board/realguest-container-report.md`:

1. **Host and build.** `sw_vers`, `uname -m`, `sysctl -n hw.model`; `git -C WT rev-parse HEAD`; debug or release; the build's
   wall time; the bundle identifier; the runner's size; `codesign --verify --deep --strict` result; the runner's entitlements
   (exactly one key?); the runtime flag.
2. **Setup actually used.** The two machines' folders and config JSON (the ids may be shown); whether tolerant decode filled the
   rest as read; the defaults key; whether the pre-seeded token was accepted or the Settings fallback was needed.
3. **Timings** (table, seconds): launch to socket; for each of runs 1 to 4 start to running, running to stopped; the build; the
   size of each `container-scratch` after the first start. Cold against warm.
4. **Run 1 and 2: the quick container.** What `start` printed, what `state` showed, whether the machine was `running` long enough to
   observe, the log text, `uname -a` containing `aarch64`, the Alpine release line, the exit status line, the final state.
5. **Run 3: the long container.** `start`, the log view text and screenshot (`realguest-container-log.png`), the process tree
   (`pgrep -P` of the app, the runner's own children), `stop` answer, time to `stopped`, the runner's exit; the forced stop.
6. **Run 4: quit with a running container.** How the app was quit, the alert if any, time to exit, whether the runner was gone
   (verdict YES / NO), the time it took.
7. **Descriptors.** `lsof -p <app pid> | wc -l` at rest, after run 1, 2 and 3 (a growth that does not return is a leak: say by
   how much, and what kind with `lsof -p <pid> | awk '{print $5}' | sort | uniq -c` once).
8. **Processes at the end.** No `ContainerRunner` left after each stop and after the app quit; any process of this run left over.
9. **Errors and surprises.** Every refusal (`-32004`, `-32001`, other), the app log's lines, anything that differed from "read
   from code" statements above (list each).
10. **Cleaned and left.** What was removed; what was left (the defaults domain if it came back, the build output, the kernel
    and image caches under the worktree if any).
11. **Verdict.** One line per question under "Why": YES / NO / NOT SEEN with the evidence.

## Stop conditions

- Not authorised; less than 10 GiB free; chain S not on `WT`; a leftover path of this run exists.
- The build fails, `codesign --verify` fails, or the runner's entitlements are not exactly the one key.
- Anything that would touch the owner's real data folder (`~/Library/Application Support/VMRunner`) or the owner's default
  control socket: a `vmr control` call without `--socket`, an app launched without `VMRUNNER_DATA_DIR`, a data folder the app
  refuses (exit 78: do not retry with another folder; record it). Stop at once and report.
- The image pull fails (no network, a registry error): record the runner's message and the app's, and STOP; no retry with another
  image or configuration (a change is a code change for the owner).
- The app crashes: record the crash report's path and STOP (after killing recorded pids).
- No `running` within 10 minutes of a start, or no socket within 60 s of launch: record and clean up.
- Anything would need a click or keystroke outside the app's own pid, or a whole-screen capture, or a permission change:
  ask the owner instead.

## After the run (not part of this card)

The owner reads the report and decides: the diary entry and the roadmap 0024 progress line for what the run showed; the status
of ADR-0057; whether to follow up the quit and stop timings, the cache growth, or the descriptor count. Each is a change of its own,
with its own cards.
