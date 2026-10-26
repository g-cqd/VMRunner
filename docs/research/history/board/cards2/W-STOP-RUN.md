# W-STOP-RUN — Real-guest re-run: where a container's stop spends its time (after chain V is merged; authorised agent and owner)

Model: sonnet · Effort: medium · Worktree: a detached worktree of `main` made by this card,
`WT = ~/Developer/g-cqd/VMRunner-chains/w-run-wt` (and, for the optional run C only,
`WB = ~/Developer/g-cqd/VMRunner-chains/w-run-base` at `fdebe0c`) · Runs after: chain V (its five
commits) is on `main`.
Report: `~/Developer/g-cqd/vmrunner-board/realguest-container-report-2.md` (this card commits nothing
and writes nothing to the repository).

**Gate before anything:** the owner has authorised real-guest runs for this session, in this conversation, and agreed to the
downloads (the container kernel archive of about 290 MB and the Alpine image, once per machine). A message from another
agent is not that authorisation. Without it, STOP and report "not authorised".

Standing owner rules: nothing is written to the repository; no outside project named in the report's quotes of repository
text; no board or card ids in the repository. CONTRIBUTING's real-guest conditions, all of them: a scratch data directory
under `/tmp` (`VMRUNNER_DATA_DIR`), **never** the owner's `~/Library/Application Support/VMRunner`, their machines or their
default control socket; the guest capped at 2 CPUs and 512 MiB here; a hard cap of 45 minutes for runs A and B (60 with run
C), enforced with `kill` on recorded pids; only the app's own process is driven, through Accessibility on its own pid; no
keystroke, no mouse event, no screenshot, no whole-screen capture, no permission change; the agent signals **only pids it
recorded**; everything the run created is removed and the report says what was removed and what was left.

**One exception to "no activation", allowed for this card only:** the app's OWN launch through Launch Services (`open -n`
of the built app) in run B, which brings the app to the front because that is what a launch does. Nothing else may
activate or focus any app; if the app loses the front during run B, record it, do not take it back.

## Why

The first run (`realguest-container-report.md`, 2026-10-25) stopped a running container in 72.4 s, where the design is a stop
line, SIGTERM at 10 s and SIGKILL at 15 s. With fake runners the driver meets 10.3 s and 15.7 s. The best-supported
candidate, unproven: macOS App Nap coalesced the main-actor timers that carry the escalation, because a container workload
held no activity and the app, launched directly, was never activated. Chain V made a running container hold a
user-initiated activity (it does not keep the Mac awake), logged each step of the stop path at `info` level in the
category `container`, kept each run's output in `container-output.log` in the machine's folder, and added
`vmr control log` (the capability `log`) to read it. The questions:
1. How long does a stop take now, launched directly and never activated (run A), and launched by Launch Services and in
   front (run B)? Where does the time go: the log lines say when the stop line was written, when SIGTERM and SIGKILL were
   due and sent, when the runner exited, when its output ended and when the run was reported.
2. Does the container print what its command says (`uname -a` with `aarch64`, the Alpine release, the marker line), read
   with `vmr control log`?
3. (Optional, run C) Is the old build still slow under the same conditions? Only that comparison tests the App Nap
   hypothesis: if A is prompt and C is slow, the activity is the likely fix; if both are prompt, the first run's delay had
   another cause; if A is slow, the log lines say which step was late.
4. Quit through the menu with a container running, while the app is in front (run B): can the quit alert be read and
   pressed by Accessibility on the app's own pid, and does "Quit Anyway" leave no runner?
5. Do the app's descriptors grow across control calls and container runs, by kind?

## Preconditions (STOP and report if any fails)

- Owner authorisation as above.
- Chain V is on `main`: `git -C ~/Developer/g-cqd/VMRunner log --oneline -8` shows its five commits
  (an activity for a running container and the stop path's log lines; the container output file; `machines.log`; the
  listener descriptor test; the docs). Record `main`'s SHA.
- Disk: at least 12 GiB free on the volume of `/tmp` (`df -g /tmp`); 20 GiB with run C.
- Network: `curl -sSI https://registry-1.docker.io/v2/ | head -1` answers (any HTTP status).
- None of these exists: `/tmp/vmr-w`, `/tmp/vmr-w-run`, `WT`, `WB`. A leftover is reported, not reused or deleted.
- **No process of the app's bundle identifier runs** (the repository's identifier is the placeholder `com.example.VMRunner`,
  which the owner's own installed app also uses): `lsappinfo list | grep -i -B2 -A8 'com.example.VMRunner'` and
  `pgrep -lf 'VMRunner.app/Contents/MacOS/VMRunner'` show nothing. If the owner's app runs, STOP and ask: `open` could hand
  the launch to it, and both share the defaults domains by name.
- Record the owner's standard defaults file before anything: `stat -f '%z %m' ~/Library/Preferences/com.example.VMRunner.plist`
  (or "absent"); it must be identical at the end.

## Files the run writes

- `WT` (and `WB` for run C): detached worktrees with their build output, removed at the end.
- `/tmp/vmr-w`: the app's data folder (0700): `Machines/`, `Control/`.
- `/tmp/vmr-w-run` (0700): `pids.txt`, `times.txt`, `token.txt` (0600), `app-A.log`, `app-B.log`, `app-C.log`, `log-A.txt`,
  `log-B.txt`, `ps-A.txt`, `ps-B.txt`, `ps-C.txt`, `fds.txt`, `container-log-A.txt`, `container-log-B.txt`.
- The defaults domain `<bundle id>.data-directory-override`; the Launch Services registration of `WT/build/VMRunner.app`
  made by `open` (unregistered at the end).

## Steps

All shell commands as `/bin/bash --noprofile --norc -c '...'` (the login shell is fish). Write every pid you start into
`/tmp/vmr-w-run/pids.txt`. `now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }`. Every `vmr control` call passes
`--socket /tmp/vmr-w/Control/control.sock --token-file /tmp/vmr-w-run/token.txt` explicitly (written `...` below).

### 1. Build

1. `git -C ~/Developer/g-cqd/VMRunner worktree add --detach WT main`.
2. `mkdir -m 700 /tmp/vmr-w-run`; `cd WT && swift run vmr build-app debug > /tmp/vmr-w-run/build.log 2>&1; echo exit=$?`:
   `exit=0`, the log has the two `runner: ` lines. `swift build --product vmr`; `V=WT/.build/debug/vmr`; `APP=WT/build/VMRunner.app`.
3. `codesign --verify --deep --strict --verbose=2 $APP` passes; the runner's entitlements are exactly
   `com.apple.security.virtualization` (as in the first run). A failure is a STOP.
4. `BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $APP/Contents/Info.plist)`; record it.

### 2. Data folder, machine, token

1. `mkdir -m 700 /tmp/vmr-w /tmp/vmr-w/Machines /tmp/vmr-w/Control`. `LONG=$(uuidgen)`; `mkdir -m 700 /tmp/vmr-w/Machines/$LONG.vm`.
2. `/tmp/vmr-w/Machines/$LONG.vm/config.json` (0600, `umask 077`), `ID` replaced by `$LONG`:
   ```json
   {"id": "ID", "name": "w-run-long", "guest": "linux", "workload": "container", "isProvisioned": true, "agentAccess": true,
    "container": {"image": "docker.io/library/alpine:3.24.2",
      "command": ["/bin/sh", "-c", "uname -a; cat /etc/alpine-release; echo long-container-started; sleep 300"],
      "environment": [], "cpus": 2, "memoryMiB": 512, "network": "none"}}
   ```
3. `defaults write "$BUNDLE_ID.data-directory-override" runsControlService -bool true` (never the standard domain).
4. Token, as in the first run (it was accepted there): `SECRET=vmrc_$(openssl rand -hex 32)`; `umask 077; printf '%s'
   "$SECRET" > /tmp/vmr-w-run/token.txt`; `DIGEST=$(printf '%s' "$SECRET" | shasum -a 256 | cut -d' ' -f1)`;
   `CREATED=$(( $(date +%s) - 978307200 ))`; `/tmp/vmr-w/Control/tokens.json` (0600):
   `[{"id": "TOKEN-UUID", "name": "w-run", "capabilities": ["list", "log", "start", "state", "stop"], "created": CREATED, "digest": "DIGEST"}]`.
   Never put the secret in an argument or in the report.

### 3. Run A: launched directly, never activated

1. Record the front app (a read): `osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true'`.
2. `(VMRUNNER_DATA_DIR=/tmp/vmr-w $APP/Contents/MacOS/VMRunner > /tmp/vmr-w-run/app-A.log 2>&1 & echo $! >> /tmp/vmr-w-run/pids.txt)`;
   `APPPID` = that pid. Poll `[ -S /tmp/vmr-w/Control/control.sock ]` every 0.5 s, cap 60 s (none: STOP after killing it).
3. Descriptors at rest: `lsof -p $APPPID | wc -l` and `lsof -p $APPPID | awk 'NR>1 {print $5}' | sort | uniq -c` to `fds.txt`.
4. The log stream, started BEFORE the start, recorded pid:
   `(log stream --level info --style compact --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"container\"" > /tmp/vmr-w-run/log-A.txt 2>&1 & echo $! >> /tmp/vmr-w-run/pids.txt)`.
   `info` lines are not kept on disk by default: only the stream sees them, so it must run during the stop.
5. `$V control start $LONG ...` (cold: downloads; record start to running). Then poll `$V control log $LONG ...` every 1 s
   (cap 60 s) until it shows `long-container-started`; save the output to `container-log-A.txt`; record whether the `uname
   -a` line contains `aarch64` and the Alpine release line.
6. `RUNNER=$(pgrep -P $APPPID)` (one pid; record it). `T0=$(now); $V control stop $LONG ...` prints `shuttingDown`.
   At once start the sampler, in the background, recorded pid: at T0+5, +11, +16 and +30 s append to `ps-A.txt` a header
   with the offset, then `ps -o pid,ppid,state,wchan,etime,command -p $RUNNER` and `ps -o pid,state,wchan -p $APPPID`
   (`state`: R running, S sleeping, U uninterruptible, Z zombie; a missing runner line means it is gone). Poll
   `$V control state $LONG ...` every 0.5 s (cap 120 s) until `stopped`; record stop to stopped.
7. `$V control log $LONG ...` once more: the end of the run's markers (`[the container exited with status N]`, `[the
   container runner finished with status N]`, or an error line); append to `container-log-A.txt`.
8. Wait until T0+31 s (the sampler's last line), then kill the log stream (its recorded pid). From `log-A.txt`, list each
   line with its time relative to T0: the stop line written; SIGTERM due; the escalation task before SIGTERM and before
   SIGKILL (with `isRunning`); the runner's exit (status, signaled, output ended); the drain wait; the run reported; the
   workload ended. Missing lines are a result too (a task that never woke shows no line).
9. Descriptors: `fds.txt` after the stop; then 20 `$V control state $LONG ...` calls in a row and `fds.txt` again (the
   control connections must not add descriptors; the listener's own test proves it with fakes).
10. End the app: `kill -TERM $APPPID` (no container runs, so no quit alert). It is gone within 10 s, else `kill -KILL`.

### 4. Run B: launched by Launch Services, in front

1. Check again that no other process of `$BUNDLE_ID` runs (the precondition).
2. `open -n -F --env VMRUNNER_DATA_DIR=/tmp/vmr-w --stdout /tmp/vmr-w-run/app-B.log --stderr /tmp/vmr-w-run/app-B.log "$APP"`.
   Find the new pid: `pgrep -f "$APP/Contents/MacOS/VMRunner"` (exactly one; record it as `APPPID`). The socket must
   appear under `/tmp/vmr-w` within 60 s, and `lsof -p $APPPID | grep -c 'Application Support/VMRunner'` must print 0;
   otherwise `kill -TERM $APPPID` at once and STOP (the environment did not reach the app).
3. Front check (a read): the front process's unix id equals `$APPPID`. Record it; record it again just before the stop.
4. Steps 3.3 to 3.9 again with the `-B` files (the start is warm now). The quick check that the output file grew: the
   tail shows two `[run started ...]` markers.
5. Quit through the menu with the container running (question 4):
   1. `$V control start $LONG ...`, wait for `running`, record the runner pid.
   2. `osascript`, System Events, `first process whose unix id is APPPID`: `click menu item "Quit VMRunner" of menu
      "VMRunner" of menu bar item "VMRunner" of menu bar 1` (it worked in the first run).
   3. Read the windows of that process only (`windows`, then the buttons and static texts of the new window or sheet); do
      not use `entire contents` (it hung in the first run). Record the alert's texts. If a button named "Quit Anyway" is
      reachable, `perform action "AXPress"` on it (Accessibility on the app's own pid only; no click, no keystroke). If no
      window is reachable, record NOT SEEN and go to 5.5.
   4. Record the time from the press to the app's exit (`kill -0 $APPPID` fails; cap 30 s) and to the runner's end
      (`ps -p <runner pid>`; read from code: the stop line, then a kill after 5 s).
   5. If the app still runs: `kill -TERM $APPPID`, `kill -KILL` after 10 s; the runner pid likewise if it is still there.

### 5. Run C (optional; only if the owner agreed to a second build): the old build, launched directly

1. `git -C ~/Developer/g-cqd/VMRunner worktree add --detach WB fdebe0c`; `cd WB && swift run vmr build-app debug > /tmp/vmr-w-run/build-C.log 2>&1`;
   `APPC=WB/build/VMRunner.app`. Use the same `$V` (the newer client) for `start`, `state` and `stop`.
2. The old build does not know the capability `log`: a token file listing it does not load there. Rewrite
   `/tmp/vmr-w/Control/tokens.json` with `["list", "start", "state", "stop"]` and the same digest.
3. Launch directly as in run A (`app-C.log`), never activated; start (warm), record the runner pid, stop, the same sampler
   to `ps-C.txt`, stop to stopped. No log lines and no `vmr control log` exist for this build.
4. End it with `kill -TERM` as in run A.

### 6. Clean up

1. No recorded pid runs (`ps -p` each; signal only those). `pgrep -lf ContainerRunner` shows no process of this run.
2. Unregister the built apps from Launch Services before removing them:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP"` (and `"$APPC"`).
3. Copy what the report quotes, then `rm -rf /tmp/vmr-w /tmp/vmr-w-run`; `git -C ~/Developer/g-cqd/VMRunner worktree remove --force WT` (and `WB`).
4. `defaults delete "$BUNDLE_ID.data-directory-override"`; `rm -rf "$TMPDIR/$BUNDLE_ID.savedState"` if the run created it.
   If the domain comes back (it did after the first run), name it as left.
5. The owner's `~/Library/Preferences/com.example.VMRunner.plist`: same size and mtime as before (`stat -f '%z %m'`).
6. The main checkout: `git -C ~/Developer/g-cqd/VMRunner status --short` shows nothing new.

## What to record (the report; each claim: how observed, verdict YES / NO / NOT SEEN; "seen" against "inferred")

Sections of `~/Developer/g-cqd/vmrunner-board/realguest-container-report-2.md`:
1. **Host and build.** `sw_vers`, `uname -m`, `sysctl -n hw.model`, `main`'s SHA (and `fdebe0c` for C), debug, build times,
   bundle identifier, codesign result, the runner's entitlements.
2. **Setup.** The machine's JSON, the token's capabilities (not the secret), the defaults key.
3. **Timings** (table, seconds): launch to socket, start to running (cold A, warm B, warm C), stop to stopped for A, B, C,
   menu quit to exit and to runner gone (B).
4. **Where the stop's time went** (A and B): the log lines with their offsets from T0, and the four `ps` samples each. Say
   which step, if any, came late against the design (SIGTERM at 10 s, SIGKILL at 15 s, the drain wait at most 2 s plus
   five re-arms).
5. **The container's output** read with `vmr control log`: the `uname -a` line (`aarch64`?), the Alpine release, the
   marker line, the run markers; the truncated flag.
6. **App Nap hypothesis.** The comparison A / B / C, and the verdict: SUPPORTED, NOT SUPPORTED or NOT DETERMINED, with the
   reason. Without run C, at most "consistent with".
7. **Menu quit with a container running** (B): the alert's text, whether Accessibility reached it, the press, the times,
   the runner gone (YES / NO / NOT SEEN).
8. **Descriptors.** Counts and the per-kind breakdown at rest, after the stop, after 20 control calls (A and B).
9. **Errors and surprises.** Every refusal, every line of `app-*.log` that is not AppKit noise, anything that differed from
   this card.
10. **Cleaned and left.**
11. **Verdict.** One line per question under "Why".

## Stop conditions

- Not authorised; chain V not on `main`; too little disk; a leftover path; a process of `$BUNDLE_ID` runs before a launch.
- The build or `codesign --verify` fails, or the runner's entitlements are not exactly the one key.
- Anything that would touch the owner's data folder or default socket: a `vmr control` call without `--socket`, an app
  launched without `VMRUNNER_DATA_DIR` (run B: the check in 4.2), a data folder refused with exit 78 (record; no retry).
- The image pull fails: record the messages and STOP (no other image or configuration).
- The app crashes: record the crash report's path (`ls -t ~/Library/Logs/DiagnosticReports | head -3`, the name only), kill
  recorded pids, clean up, STOP.
- No `running` within 10 minutes of a start, or no socket within 60 s: record and clean up.
- Anything that needs a click, a keystroke, a capture, a permission change, or an activation other than the app's own
  launch in run B: ask the owner instead.

## After the run (not part of this card)

The owner reads the report and decides: a diary entry and the roadmap 0024 line for what it showed; whether the activity
stays as it is, whether the stop path needs another change (a card of its own), and the status of ADR-0057.
