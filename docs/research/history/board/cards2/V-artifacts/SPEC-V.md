# Chain V spec (input for the developing agents; the cards are written from the gated result)

Base: VMRunner main at fdebe0c (or later). Four code commits V01..V04, one docs commit V05. Names below are DECIDED: do not
rename. If a decision cannot be built as written (lint, analyzer, compiler), make the smallest change that works and REPORT it.

## Standing rules (every commit)
- No outside project named in code, docs, comments or commit messages ("the container package"); no board/card ids
  (V01, S06, ...) anywhere in the repository; no distribution plans.
- Swift 6.4 strict memory safety (`unsafe` on the expression; no `String(format:)`); warnings are errors; SwiftLint strict:
  type_body_length 300, function_body_length 60, cyclomatic_complexity 12, lines < 140 columns, large_tuple 3,
  empty_count, optional_data_string_conversion. Silence a false positive only with `// swiftlint:disable:this <rule>`; never
  edit .swiftlint.yml. Deadwood: prefer wiring a use; else trailing `// @dw:accept:this <rule> -- <reason>`.
- Swift Testing only. TestKit AsyncGate / AsyncEventProbe / TestClock; no real sleeps in tests; no nonisolated(unsafe).
- Tests use scratchDirectory() and fake runners (a /bin/sh script the test writes, 0700). Never start a VM, never run the real
  ContainerRunner, never touch ~/Library or the app's real data folder. A test writing to a pipe or socket whose peer may
  never read sets the writing end non-blocking.
- Never touch: Package.swift, Package.resolved, .vmr.json, .swiftlint.yml, analyzer baselines, Sources/VMRunner/Network,
  Sources/VMRunner/Policy, Sources/NetPolicy, Sources/NetStack, Sources/TestKit, Sources/VMHelper*, Sources/GuestConsole,
  Sources/VMRunner/Model/Security.swift.
- Each commit: swift-format format -i on touched .swift files; `swift run vmr check` 8/8 PASS read line by line before the
  commit; one atomic commit (signed with -S if the key works in the scratch clone; say if not).
- A test that fails (an existing one or a new one): STOP and report. Never weaken a test. Existing test edits are allowed ONLY
  where this spec lists them.
- Logging: unified logging `Log.<category>`; numbers, booleans and durations interpolated with `privacy: .public`; never a
  path or container text in a log message.

## V01 — A running container holds an activity, and the stop path logs where its time goes
Why: in the first real run a stop of a running container took 72 s (design: stop line, SIGTERM at 10 s, SIGKILL at 15 s). With
fake runners the driver meets 10.3 s / 15.7 s. Best-supported candidate (unproven): App Nap coalescing the main-actor sleep
timers that carry the escalation, because a container workload holds no activity and the app was never activated.
1. `Sources/VMRunner/Model/Log.swift`: add `static let container = Logger(subsystem: subsystem, category: "container")`.
2. `ContainerWorkload`: `init(process:scratch:host: any ActivityHost = ProcessInfo.processInfo)`; `static let activityOptions:
   ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep` (NOT latencyCritical; does not keep the Mac awake);
   `static let activityReason = "A container is running and its stop must keep to its time limits"`. Begin the activity right
   after `try process.start()` returned (a start that throws holds nothing); end it first thing in `ended(_:)`; an
   `isolated deinit` ends a held activity (a workload released mid-run). Doc comment says why (App Nap, timers, not awake).
   One `Log.container.info` in `ended(_:)` (failure yes/no, stopAsked, killed).
3. `ContainerProcess`: `Log.container.info` lines with the runner pid (`handle.process.processIdentifier`, public):
   in `stop()` (stop line written; SIGTERM due after stopGrace), in the escalation task right before `terminate()` and right
   before `forceKill()` (with `handle.isRunning`), in `kill()` (forced), in `apply` for `.terminated` (status, signaled,
   stdoutEnded, stderrEnded), for `.drainExpired` (rearmed yes/no), and in `reportIfClosed` when the run is reported.
4. Help (`Sources/VMRunner/Help/HelpContent+Machines.swift`, entry `.containers`, advanced): one sentence: while a container's
   runner runs the app holds a user-initiated activity (not latency-critical, the Mac still sleeps when idle) so that macOS
   does not slow the app down and delay the stop's time limits.
5. Tests (new file `Tests/VMRunnerTests/ContainerActivityTests.swift`, spy ActivityHost recording options and begin/end):
   (a) after start returned exactly one activity begun with `activityOptions` (and without `.latencyCritical`), none ended;
   after a stop line and the runner's exit: ended once; (b) a start that throws (executable missing) begins none;
   (c) a runner that exits with failure before it is ready: begun once, ended once, start throws; (d) a workload released while
   its runner runs ends its activity (the process deinit kills the runner). Use fake runners and TestClock where escalation
   is involved; registry `ContainerProcesses()` per test.
   `Tests/VMRunnerTests/WorkloadSeamTests.swift` ("a workload without a screen holds nothing", about the controller's
   LATENCY activity with a fake workload) is NOT changed: it does not concern the container's own activity.

## V02 — Each container run's output is kept in a private, bounded file in the machine's folder
1. `VMBundle` (`Sources/VMRunner/Model/Storage.swift`): `var containerOutput: URL` = `container-output.log`,
   `var previousContainerOutput: URL` = `container-output.1.log`, `func discardContainerOutput()` (removes both, ignores
   missing).
2. New `Sources/VMRunner/Engine/Container/ContainerOutputFile.swift`: `final class ContainerOutputFile: Sendable`.
   - `static let defaultLimit = 1 << 20`; `init(current: URL, previous: URL, limit: Int = defaultLimit, pendingLimit: Int =
     defaultLimit)`; `convenience init(bundle: VMBundle)` (or a static `for(_:)`).
   - `func append(_ bytes: [UInt8])`: callable from the main actor, never blocks on the disk: bytes go into a Mutex-held
     pending buffer and one drain is scheduled on a private serial DispatchQueue (utility QoS) when none is scheduled. Past
     `pendingLimit` pending bytes, new bytes are dropped and counted; the next drain first writes
     `[dropped N bytes: the disk was slower than the container]\n`.
   - A drain opens, writes everything pending, and closes: no descriptor outlives a drain. Opening: an existing file with
     `O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC`, then fstat: must be a regular file, owned by geteuid(), one link, mode &
     0o077 == 0; otherwise refused (one Log.container.error per refusal kind, no path in it) and the bytes dropped. A missing
     file is created with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC`, mode 0600 (fchmod 0600 after, against the
     umask). Partial writes and EINTR are handled.
   - Rotation: when size + pending > limit, rename current over previous (one previous file kept, the older one replaced),
     then create current exclusively. A drain bigger than limit keeps its last `limit` bytes, cut forward to a UTF-8 character
     boundary.
   - `func drained() async` (waits for every queued drain; tests use it).
   - `static func tail(current: URL, previous: URL, limit: Int) -> (text: String, truncated: Bool)` (use a small struct
     `ContainerOutputTail` if the tuple trips lint): reads, with the same O_NOFOLLOW + fstat checks (O_RDONLY), at most the
     last `limit` bytes of previous ++ current (pread/lseek, never the whole file into memory past limit), cut forward to a
     UTF-8 boundary; truncated = there was more. Missing files read as empty. A file that fails the checks reads as empty.
     Not main-actor isolated.
3. `ContainerLog`: `init(limit: Int = defaultLimit, file: ContainerOutputFile? = nil)`. When a file is given: at init append
   `[run started <ISO 8601 UTC>]\n`; in `apply(.output)` append the SAME displayable bytes that go to `output`; on `.exited`
   `[the container exited with status N]\n`; on `.finished` `[the container runner finished with status N]\n`; on `.error`
   `[runner error] <the plain, cut message>\n`. Diagnostics (runner stderr) are NOT written to the file.
4. `ContainerMachineFactory.prepare`: `ContainerProcess(..., log: ContainerLog(file: ContainerOutputFile(bundle: bundle)))`.
5. `VMLibrary.duplicate`: the staged copy discards its container output (`staged.discardContainerOutput()`), so a copy starts
   with no log. `delete` already removes the bundle folder (a test pins that the log goes with it).
6. Help `.containers`: the Output bullet says the output is also kept in `container-output.log` in the machine's folder (mode
   0600, the most recent 1 MiB and one previous file of 1 MiB, filtered the same way), removed with the machine and not
   copied by Duplicate. Advanced: the run start/exit marker lines.
7. Tests (new `Tests/VMRunnerTests/ContainerOutputFileTests.swift`, plus additions where the factory/library tests live):
   created 0600 exclusively; appends across two writers (two runs); rotation at a small limit keeps exactly one previous; a
   symbolic link at the path is refused and its target untouched; a file open to others (0644) is refused and unchanged; a
   second hard link is refused; one append bigger than the limit keeps its last bytes at a character boundary; the pending
   limit drops and the marker is written; tail: at most limit, crosses into previous, cut at a UTF-8 boundary, truncated
   flag, missing files empty; ContainerLog with a file writes exactly the filtered text (an escape sequence in the container
   output is absent from the file) and the markers; a container machine run through the factory with a fake runner leaves
   `container-output.log` in its bundle with the output; delete removes it; duplicate does not carry it.

## V03 — `machines.log`: a read-only control method, its capability, `vmr control log` and the MCP tool `machines_log`
1. ControlProtocol:
   - `ControlCapability.log` (raw "log"), label "Read a container's log".
   - `ControlMethod.log = "machines.log"`, capability `.log`, parameters ["token", "machine"].
   - `public struct ControlLog: Codable, Equatable, Sendable { id: UUID; text: String; truncated: Bool;
     public static let maxBytes = 65_536 }` plus a public helper that keeps the last N bytes of a byte array or string cut
     forward to a UTF-8 boundary (one helper, used by the dispatcher, the app and the CLI).
   - `public enum ControlLogOutcome: Equatable, Sendable { case text(String, truncated: Bool); case refused(String) }`.
   - `ControlMachines` gains the REQUIREMENT `func log(_ id: UUID) async -> ControlLogOutcome` (no default implementation).
   - Dispatcher: same order of checks as machines.state (method, params, token, capability, scope, machine exists, agent
     access); `.log` → result `ControlLog` (text re-cut to maxBytes whatever the adapter returned, truncated set) or -32004
     with the refusal. Params stay strings and booleans only: the method takes no size; the tail is always at most 64 KiB.
2. App `LibraryControlMachines.log`: denied policy → the closed refusal; agent access off → refused like start/stop; a machine
   whose workload is not a container → refused "This machine is not a container; only a container machine keeps an output
   log."; else read `ContainerOutputFile.tail(current:previous:limit: ControlLog.maxBytes)` OFF the main actor.
3. Exposure: `Sources/VMRunner/Model/ContainerExposures.swift`: when agentAccess, after `agentAccessExposure`, one more line
   (level .low): the control service exposes the container's output to a token holder: "Container output: a script or AI
   agent whose control token has the log capability can read the last 64 KiB of what this container printed while the
   control service is on." (wording may be tightened; keep the facts). Security.swift is not touched.
4. Help: `HelpContent+Automation.swift` (agentAccess, controlService, controlTokens: the capability list and the method list
   include the log; agentAccess's "It cannot see the screen..." sentence stays true for a VM and says a container's output
   can be read with the log capability); `.containers` agent-access sentence.
5. CLI `Sources/DevTools/CLI/ControlCommand.swift`: subcommand `Log`: `vmr control log MACHINE [--bytes N] [--json]`, N in
   1...65536 (default 65536; outside is a usage error, exit 64); prints the last N bytes of the text (cut at a character
   boundary, client side); when the service said truncated or N cut it, first prints a line `[earlier output not shown]`.
   `--json` prints the service's answer. Discussion: needs a token with the log capability; only a container machine has a
   log. Update the top-level subcommand list and the MCP discussion ("five tools", machines_log). CONTRIBUTING's
   `vmr control` block gains the log line.
6. MCP `Sources/AgentBridge/MCPTool.swift`: `case log = "machines_log"`, method `.log`, title "Read a container's log",
   summary, required machine, annotations readOnlyHint true, openWorldHint false.
7. Every ControlMachines conformer in tests implements `log` (FakeMachines, StaticMachines, MemoryMachines, TwoMachines);
   FakeMachines returns a short text for a known machine so `eachMethodNeedsItsOwnCapability` passes for `.log` too.
   Existing test edit allowed: `Tests/AgentBridgeTests/MCPServerTests.swift` tools/list expectation gains "machines_log".
8. Tests: dispatcher (needs log capability; outside scope -32001; agent access off -32003; no such machine -32002; refused
   -32004; an adapter text of 100 KiB comes back as its last 64 KiB with truncated true); protocol limits (a 64 KiB tail of
   the worst-case characters for JSON escaping — `"`, `\`, `/`, newline, tab, multi-byte — round-trips exactly through a
   ControlConnection and ControlClient pair and its answer line is under ControlClient.defaultAnswerBytes); a tokens.json with
   "log" decodes and the label is shown; adapter (container with a log file → its tail; VM → refused; agent access off →
   refused; organisation off → closed); CLI (`control log` text, `--bytes 5`, `--bytes 0` and `--bytes 65537` exit 64,
   `--json`); MCP (tools/list has machines_log with readOnlyHint; a call answers the text).

## V04 — The control listener closes every connection it accepts (test only)
New `Tests/ControlProtocolTests/ControlListenerDescriptorTests.swift`, a `@Suite(.serialized)` of its own. Paths, each
showing the server closed its end (the client reads end of file / ControlClient returns nil or throws .closed within the
test): a normal call then client close; a client of another user (connection's peerUser closure returns another uid); a
client past the connection limit; a request longer than limits.requestBytes; a silent client past a small
readTimeoutMilliseconds; requestsPerConnection exhausted; a connection open when the listener stops. Then a /dev/fd count:
before = the minimum of 5 reads of /dev/fd entries; run N = 128 connections mixing the paths; wait until the limiter would be
free (poll a call that succeeds, no sleeps); after = the minimum of 5 reads; expect after - before < 32 (a leak of one
descriptor per connection shows +128; the slack absorbs other suites running in parallel, which `.serialized` does not stop).
Source unchanged. If a path leaks: STOP and report it (that is a finding for a fix card, not a test to bend).

## V05 — Docs (written last, from what V01-V04 did)
ADR-0057 dated note; ADR-0056 dated note (a method and a capability were added); roadmap 0024 (Left item 1: the run happened,
what it showed, the follow-ups; new Left items for what remains); a diary entry (next free number from `ls docs/diary` at
execution time); what remains unverified: the App Nap hypothesis, the menu-quit path, descriptor growth in the app.
