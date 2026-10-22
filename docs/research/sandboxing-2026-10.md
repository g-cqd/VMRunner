---
date: 2026-10-21
question: "How can App Sandbox and Seatbelt isolate VMs and containers, per app or per workload?"
feeds: [roadmap 0025, ADR-0016]
---
# Sandboxing virtual machines, containers and helpers

Study, not a decision record. Host: macOS 26.7.1; SDK: macOS 27. Items marked *unverified* were not run or could not be
confirmed from a primary source.

## Short answer

- Offer **both** primitives: App Sandbox driven by entitlements (supported), and Seatbelt profiles through `sandbox-exec`
  (works today; undocumented and unsupported for third parties).
- **They cannot be stacked on one process** (tested below, in both orders). They are alternative *engines* for a workload.
  Isolation in depth comes from separate layers instead: the hypervisor boundary, Apple's own sandboxed per-VM service, a
  helper process under one of the two engines, and the network policy in the user-mode stack.
- **Neither engine, nor all of them together, guarantees full isolation.** A sandbox narrows what a process may touch; the
  kernel, the entitlements it keeps and the profile's own mistakes remain the attack surface. The help must not say
  otherwise.
- The boundary that matters most is **one helper process per workload**.
- **Hard limit:** a virtual machine's display view is an in-process `NSView`; no public API exports its framebuffer to
  another process. Headless workloads (containers, server guests) can live in helpers; GUI machines stay in the app.

## What is public and what is not

| Layer | Status | Evidence |
|---|---|---|
| App Sandbox (`com.apple.security.app-sandbox`, `~/Library/Containers`) | Public, supported | Apple's Security documentation |
| `sandbox-exec(1)` | Man page: "DEPRECATED"; tells developers to adopt App Sandbox | `/usr/share/man/man1/sandbox-exec.1` |
| `<sandbox.h>` | Header says it "is deprecated and may be removed in a future release"; `sandbox_init` is marked no longer supported; a profile is ignored if the process is already sandboxed | `usr/include/sandbox.h` in the macOS 27 SDK |
| `sandbox_init_with_parameters`, `sandbox_apply_bytecode`, `sandbox_extension_*`, `sandbox_check*` | Exported by libsystem_sandbox, not declared publicly (SPI) | `usr/lib/system/libsystem_sandbox.tbd` |
| SBPL, the profile language | Not documented for third parties | Apple Developer Technical Support, forum threads 661939 and 777509 |
| Hardened runtime | Public; code-signing hardening, not an access-control sandbox | Apple documentation |
| Enhanced Security entitlements | Public; memory and runtime hardening, not a resource sandbox | Apple documentation |
| Endpoint Security | Public API but needs a restricted entitlement; macOS 27 adds a client that sees only a process's descendants | `ESClient.h` in the SDK |

Apple's engineers have said that building a product on custom SBPL "would be unwise". A request to the containerization
project for a deprecation timeline and a replacement is open and unanswered.

## What was run on this host

`sandbox-exec` is present and **still works on macOS 26.7.1**, with no deprecation notice printed.

| Profile | Command | Result |
|---|---|---|
| `(deny default)(allow process-exec*)` | `/usr/bin/true` | Aborts, exit 134: `dyld` cannot read the system libraries under deny-default |
| `(allow default)(deny file-read* (subpath "/private/etc"))` | `/bin/cat /etc/hosts` | `Operation not permitted`, exit 1 |
| `(allow default)(deny network-outbound)` | `curl http://example.com` | `Could not resolve host`, exit 6 (the resolver is blocked too) |
| deny outbound, allow `(remote ip "*:443")` | `curl https://example.com` | Same resolver failure, exit 6 |

The last two matter for design: a profile that restricts the network must also let the process reach the system resolver
(the `mDNSResponder` socket and its Mach service), or name lookups fail before any connection is attempted. Apple's
diagnosing article lists the same failure.

## Can the two be combined? Tested

On macOS 26.7.1, with tiny programs in `/tmp`, packaged as minimal apps and signed ad hoc with the
`com.apple.security.app-sandbox` entitlement (a bare executable with that entitlement traps, because it needs a bundle
identifier from an embedded Info.plist):

| Setup | Result |
|---|---|
| App Sandbox app, run directly | Works. `HOME` becomes `~/Library/Containers/<id>/Data`; writing under `/tmp` is denied; reading `/etc/hosts` is still allowed |
| Plain executable under `sandbox-exec` with a write deny | Works. The write is denied; everything else is unchanged |
| App Sandbox app launched **under** `sandbox-exec` (even `allow default`) | **Aborts**, exit 133 |
| `sandbox-exec` run **from inside** an App Sandbox app | **Fails**: `sandbox_apply: Operation not permitted` |

So a process gets one sandbox. An App Sandbox app cannot launch a Seatbelt-wrapped child, and a Seatbelt-wrapped process
cannot become an App Sandbox app. This matches `sandbox.h`: a profile is ignored when the process is already sandboxed.

Consequences for the design:

- The **main app stays unsandboxed** (Developer ID or ad-hoc distribution, not the Mac App Store), so it can launch helpers of
  either kind. An App Sandboxed main app could not launch Seatbelt helpers.
- Each workload's helper uses **one** engine: an App Sandbox helper bundle with its own entitlements, or a plain
  helper launched through `sandbox-exec -f profile.sb` (or applying the profile itself at start-up with the SPI call).
- Running a virtual machine inside a `sandbox-exec` helper is **unverified**: the profile must allow the Mach services the
  framework uses, and the helper still needs the virtualization entitlement. That is the first thing the prototype checks.

## Facts that decide the design

**What Apple already does for a virtual machine.**
- Each VM runs in its own `com.apple.Virtualization.VirtualMachine` XPC service instance. It is not App Sandboxed; it runs
  a bundled Seatbelt profile that denies by default, denies reads under `/Users`, allows a short Mach-lookup list and gates
  each device capability on a per-feature sandbox extension (`com.apple.virtualization.extension.*`: bridged networking,
  USB passthrough, audio in and out, paravirtualized graphics, Linux GPU acceleration, Rosetta share).
- File access reaches that service as `com.apple.app-sandbox.read` and `.read-write` extensions.
- *Inference, not documented:* the framework issues exactly the extensions your `VZVirtualMachineConfiguration` implies, so
  the helper already follows least privilege, and the app cannot add rules to it.

**How Apple's container tooling does it.** Its runtime helpers are signed with only `com.apple.security.virtualization`,
run one per container, and are not App Sandboxed. Isolation comes from the per-container virtual machine and the process
split.

**Entitlement requirements in the SDK headers.**
- Bridged networking: restricted `com.apple.vm.networking`; avoid.
- Network block device storage: `com.apple.security.network.client`.
- Loading a macOS restore image: `com.apple.security.virtualization`.
- A vmnet network can only be used by the process that created it, and creating one needs an entitlement.
- Every call on a `VZVirtualMachine` must run on its queue (the main queue by default; a custom serial queue from macOS 26).

**What Seatbelt can enforce.** Path rules (literal, subpath, regex), Mach lookups, `sysctl` names, IOKit opens, process
exec, signals, ioctls, and network by remote address and port pattern, but **never by domain name**. File rules apply when
a file is opened: a descriptor opened before the profile applies keeps working, which is why passing descriptors into a
helper is workable. A child inherits its parent's sandbox. Apple's system profiles are marked as private and subject to
change.

## Feasibility

| Scope | App Sandbox | Seatbelt via `sandbox_init_with_parameters` (SPI) | `sandbox-exec` (deprecated) | Separate process / XPC |
|---|---|---|---|---|
| Whole app | Feasible, public. Needs `app-sandbox`, `virtualization`, user-selected file access with security-scoped bookmarks, `network.client` for downloads and the user-mode stack's host sockets. Avoid `com.apple.vm.networking`. | Not worth it | Cannot wrap an already-running GUI app | – |
| One VM, in the app | Partial. The sandbox is per process, so no per-VM difference; Apple already sandboxes the per-VM service | No | No | Partial |
| One VM, in its own helper | Feasible for headless VMs | Partial; SPI | Partial | Feasible. A GUI VM is not feasible across processes with public API |
| One Linux container | Feasible as an extra layer around the runtime helper (untested) | Partial; SPI | Partial | Feasible; matches Apple's one-helper-per-container model |
| A cloned macOS VM | Same as one VM | – | – | Same as one VM |
| A macOS process, as a "container" | No: needs a signed, entitled executable | Feasible, unsupported: a deny-default profile per workload | Feasible, unsupported: `-f profile.sb -D key=value command` | Partial: macOS 27's descendants client needs a restricted entitlement |
| A helper process | Feasible, public; a helper inherits the sandbox with `com.apple.security.inherit`, or is signed separately with its own entitlements | Feasible; cannot be applied twice | Feasible | Feasible, public |

## Settings model

One setting with an app-wide default and a per-workload override:

`SandboxEngine`: `none`, `appSandbox`, `seatbelt`.
`SandboxLevel`: `standard`, `strict`, `custom` (what the engine is asked to allow).

- `none`: in the app, or in a helper signed with the virtualization entitlement only (Apple's own container setup).
- `appSandbox` + `standard`: a helper bundle with `app-sandbox`, `virtualization` and `network.client`; file access only from
  descriptors and bookmarks handed over by the app.
- `appSandbox` + `strict`: as above without network entitlements; the guest's network comes from the user-mode stack through
  a file-handle attachment, so the helper never opens a socket of its own.
- `seatbelt` + `standard` or `strict`: a generated deny-default profile per workload (paths it may read or write, Mach
  services, address and port patterns for the network), applied with `sandbox-exec -f` or at start-up in the helper.
- `seatbelt` + `custom`: a user-supplied SBPL template with parameters, labelled advanced and unsupported.

Engines are exclusive per workload; the interface says so and explains why. Defence in depth is shown as the list of layers
that apply to that workload: hypervisor, Apple's per-VM service, the chosen engine, the network policy.

Order of operations in a helper: spawn it, apply the sandbox before it touches guest data, receive descriptors over XPC,
then create the `VZVirtualMachine` on the helper's own queue. The network policy remains the domain-level control; the
sandbox is a coarse backstop (address and port patterns, Mach-lookup allow-list).

Debugging: Console filtered on subsystem `com.apple.sandbox.reporting`; the unified log for the `Sandbox` sender
(*predicate unverified*); the sandbox daemon's reports.

## Plan

1. **Prototype (days):** a headless helper for one Linux VM or container, signed with only the virtualization entitlement.
   Pass the disk and share descriptors over XPC. Measure boot time and count sandbox denials in the log.
2. **Two engines on that helper:** (a) as an App Sandbox bundle (`app-sandbox`, `virtualization`, optionally
   `network.client`); (b) as a plain helper under a generated Seatbelt profile. For each, check NAT, shared folders and the
   user-mode stack, and name resolution first. Record which Mach services the profile needs.
3. **Settings model, per-workload override and interface.** Keep GUI machines in the app.
4. **Seatbelt for macOS process-level containers** (native binaries, no virtual machine), outside the App Store build.

## Risks

- Offering Seatbelt means the app is not a Mac App Store build: the store requires App Sandbox on the main app, and a
  sandboxed main app cannot launch Seatbelt helpers (tested). SPI use would likely be rejected anyway (*inference*), and the
  restricted networking entitlement needs Apple's approval.
- No deprecation timeline exists for `sandbox-exec`; profile maintenance is ours.
- Helper sandboxes can break when macOS changes its allowed Mach lookups. Keep a regression test that boots a workload at
  each level.

## Probe results (2026-10-22)

The prototype of the plan above was built and run without starting a machine: everything below was run on the host named
at the top (an Apple M3, macOS 26.7.1, SDK macOS 27) with `--probe` and `--dry-run`. **Whether a guest boots inside
either engine is not known yet**; the owner's run, described below, decides it.

### What compiled

- `Sources/VMHelperCore` (library): the JSON descriptor and its path checks, the line-delimited events, the exit-status
  mapping, the grants both engines are derived from, and the Seatbelt profile generator. Pure Swift with unit tests.
- `Sources/VMHelper` (executable): links the system frameworks and `VMHelperCore` only, never the app. `--dry-run` builds the
  `VZVirtualMachineConfiguration` and calls `validate()` without creating a machine; `--probe` tries the operations a
  helper needs and reports each as allowed or refused; `--start` boots (owner only). Events go to standard output
  (`booting`, `running`, `stopped`, `error`, `validated`, `probe`), the guest's serial console to standard error. Exit
  statuses are the `sysexits.h` values: 0, 64 usage, 65 bad descriptor, 66 file missing or hidden, 69 configuration
  rejected, 70 start failed.
- `vmr sandbox run --engine none|seatbelt|app-sandbox --level standard|strict --descriptor FILE [--boot]` builds and
  signs the helper for the engine, launches it, reads the denials of its pid from the unified log, and prints the report.
  `vmr sandbox profile` prints the generated Seatbelt profile. The signing code is in `Sources/DevTools/App`, next to
  `AppBundler`, with the entitlements in `Resources/VMHelper*.entitlements` and the bundle's `Resources/VMHelper.Info.plist`.
- The app target gained no dependency, and `swift run vmr check` is green. The helper copies the minimum of the app's
  `ConfigurationBuilder` (Linux, EFI or kernel boot, disks, an ISO, entropy, NAT, a file-handle NIC). The app's user-mode
  network stack (about 5,000 lines in `Sources/VMRunner/Network`) was **not** copied, so a machine started by the helper
  has a NIC on a socket pair that nothing serves. Extracting the stack and the builder into libraries is the follow-up that
  lets the app and the helper share them.

### How the engines were set up

- `none`: the helper signed ad hoc with the hardened runtime and only `com.apple.security.virtualization`. The entitlement
  is needed even by `--dry-run`: `validate()` on an unsigned binary fails with "The process doesn't have the
  com.apple.security.virtualization entitlement".
- `app-sandbox`: a bundle (a bare executable with `app-sandbox` traps, as the tests above found) signed with `app-sandbox`
  and `virtualization`, plus, for the descriptor, `com.apple.security.temporary-exception.files.absolute-path.read-only`
  and `.read-write` arrays naming each path, plus `network.client` at the standard level when the helper hosts the guest's
  network. `vmr` reads the entitlements back from the signed bundle and fails if they differ from what was asked.
  **How the sandboxed helper reaches files** was decided by what worked: with no path entitlement the helper cannot even
  read its descriptor (status 66); with the exceptions it can. A file descriptor cannot carry a disk, because the
  framework's disk attachment takes a URL. A security-scoped bookmark is documented to resolve only in the app that made it,
  so an unsandboxed launcher could not hand one to a separately signed helper (not tested here). Staging the files inside
  the helper's container was not tried. The price of the exceptions is that the grants live in the signature, so the bundle
  is signed again for each descriptor (ad hoc, milliseconds), and that the exception entitlement is unavailable to a Mac App
  Store build, which the app already is not. Running the helper creates
  `~/Library/Containers/com.example.VMRunner.VMHelper`.
- `seatbelt`: the plain helper under `sandbox-exec -f build/sandbox/seatbelt-<level>.sb`. The generated profile
  (`vmr sandbox profile` prints it) is `(deny default)`, `(import "dyld-support.sb")`, the helper's `process-exec`,
  system reads, nine `sysctl-read` names, four Mach lookups, one shared-memory name, a `file-read-metadata` rule for each
  directory above a granted file, and for each granted file a `literal` rule plus the `file-issue-extension` rules meant to
  let the framework hand the file to the per-machine service. The standard level with a hosted network adds outbound sockets
  and the resolver.

### What running it showed

Every combination of the three engines, both levels and two descriptors (EFI boot with an ISO, a disk and a file-handle NIC;
kernel boot with an initial ramdisk, a disk and the NAT attachment) **validated**: `validate()` succeeded inside App Sandbox
and inside the Seatbelt profile, which is the first evidence that neither engine stops the framework from building a
configuration. The probe, with the first descriptor:

| Operation (as the helper saw it) | none | Seatbelt standard | Seatbelt strict | App Sandbox standard | App Sandbox strict |
|---|---|---|---|---|---|
| open the granted files (ISO, disk) | allowed | allowed | allowed | allowed | allowed |
| datagram socket pair, a datagram crossing it | allowed | allowed | allowed | allowed | allowed |
| connect TCP, send UDP, connect an ICMP echo socket | allowed | allowed | refused | allowed | refused |
| resolve `example.com` | allowed | allowed | refused | allowed | refused |
| read `/etc/hosts`, resolve `localhost` | allowed | allowed | refused | allowed | allowed |
| bind a UDP socket on loopback | allowed | refused | refused | refused | refused |
| list the real home directory | allowed | refused | refused | refused | refused |
| create a file under `/private/tmp` | allowed | refused | refused | refused | refused |

The second descriptor (NAT) at the standard level gave the strict column's socket results in both engines, because only a
network the helper hosts asks for host sockets.

What the denials and the refusals mean:

- **The strict level is real in both engines.** Without any network permission the socket pair still works, so a guest
  network that arrives as a descriptor needs no entitlement and no rule, while every outbound socket and the resolver are
  refused. That is the strict design in the settings model.
- **The two engines do not give the same baseline.** App Sandbox still lets a process read `/etc/hosts`, so `localhost`
  resolves at the strict level; the generated profile refuses it. A level cannot promise identical behaviour across
  engines; it can promise "no host sockets".
- **Binding is a separate permission.** App Sandbox refused `bind` with only `network.client` (it documents
  `network.server` for this; not tried), and the profile omits `network-bind`. The user-mode stack connects and never
  binds, so it should need neither.
- **What the profile needs to start at all**, found one denial at a time: the loader's bootstrap, which is why the profile
  imports Apple's private `dyld-support.sb` (without it the process aborts with status 134 before it runs a line, and the
  log shows no denial); the real path of every file (`/tmp` is a link, and a rule for `/tmp/x` never matches);
  `file-read-metadata` on every directory above a granted file; `sysctl-read` of `kern.hv_support` (without it
  `validate()` says virtualization is unavailable on this hardware) and eight more names; the Mach service
  `com.apple.diskimagescontroller`, which the framework asks to validate a disk image; `com.apple.logd` and
  `com.apple.system.notification_center`; the shared-memory name `apple.shm.notification_center`. Left denied, harmlessly:
  `/dev/dtracehelper` and the `syslog` socket.
- **A path holding a quote, a backslash or a newline cannot be written into a profile.** A `"` ends the quoted string and
  the rest is parsed as code (`sandbox-exec: unbound variable`), so the descriptor reader and the generator both refuse
  quotes, backslashes and control characters, relative paths and `..`. Parentheses, semicolons and spaces inside the quoted
  string are inert and accepted (checked with `sandbox-exec -p`).
- **The unified log undercounts.** The predicate `sender == "Sandbox" AND eventMessage CONTAINS "(<pid>) deny"` returns lines
  such as `Sandbox: <name>(<pid>) deny(1) <operation> <target>`, and the launcher's pid is the helper's (`sandbox-exec`
  replaces itself). But the kernel throttles these lines: three consecutive launches of the same App Sandbox helper logged
  0, 0 and 1 of the same three denials, and the next three logged 3, 3, 3. A `log stream` running alongside recorded
  exactly what `log show` returned, so the lines were never emitted. The report therefore trusts the helper's own
  `refused` verdicts and treats the log as a lower bound.
- Cost: a probe or a dry run takes 30 to 150 ms in any engine. Boot time was not measured.

### What this means for the model in ADR-0016

- **Engines.** `none`, `appSandbox` and `seatbelt` hold up as three renderings of one set of grants (files to read, files to
  write, host sockets or not), derived once from the workload. That is how the helper is built, and both engines accepted the
  same configurations.
- **Levels.** `standard` and `strict` are meaningful as "may the helper open host sockets"; nothing else was needed to tell
  them apart. `custom` was not exercised.
- **File access for App Sandbox helpers is the open design question.** Temporary exceptions work but put the grants in the
  signature, so the helper bundle is re-signed per workload. Whether an ad-hoc re-signed bundle may be launched by a
  notarized app, and whether cloning a workload's disks into the helper's container is better, are not tested. The ADR's
  "What this does not decide" should gain this.
- **A regression test cannot rely on the log.** The "boot a workload at each level" test in the risks above must read the
  helper's events and probe verdicts.
- **A virtual machine inside a Seatbelt helper is still unverified**, as is every Mach service the framework looks up when a
  machine starts. The profile lists `com.apple.Virtualization.VirtualMachine` as a guess. ADR-0016 is not changed by these probes.

### The owner's boot run

Agents never start virtual machines, so one run is left. It needs an Apple silicon Mac, a checkout of this repository, an
arm64 Linux installer ISO (the smallest one the app offers is enough) and about ten minutes. The helper writes the disk, so
use scratch copies.

```sh
mkdir -p ~/sandbox-run && cd ~/sandbox-run
truncate -s 8g disk.img                      # an empty raw disk, sparse on APFS
cp /path/to/linux-arm64.iso linux.iso        # any arm64 installer ISO that boots under UEFI
cat > d.json <<'JSON'
{ "version": 1, "name": "sandbox-run", "cpuCount": 2, "memoryMiB": 2048,
  "boot": { "kind": "efi", "variableStore": "/Users/YOU/sandbox-run/efi.nvram" },
  "disks": [ { "path": "/Users/YOU/sandbox-run/disk.img" } ],
  "installerISO": "/Users/YOU/sandbox-run/linux.iso", "network": "fileHandle" }
JSON
sed 's/"fileHandle"/"nat"/' d.json > d-nat.json
```

Paths must be absolute. Then, from the repository root (the first command builds the helper, which takes a few minutes):

```sh
swift run vmr sandbox run --engine none        --descriptor ~/sandbox-run/d.json --boot --run-seconds 40
swift run vmr sandbox run --engine seatbelt    --descriptor ~/sandbox-run/d.json --boot --run-seconds 40
swift run vmr sandbox run --engine app-sandbox --descriptor ~/sandbox-run/d.json --boot --run-seconds 40
swift run vmr sandbox run --engine seatbelt    --descriptor ~/sandbox-run/d-nat.json --boot --run-seconds 40
swift run vmr sandbox run --engine app-sandbox --descriptor ~/sandbox-run/d-nat.json --boot --run-seconds 40
```

Each run probes, validates, then starts the machine, lets it run for `--run-seconds`, and stops it; it takes about a minute
plus ten seconds for the log. Run `none` first: it is the control, and if it fails the others mean nothing.

Expected on success, at the top of the report:

```
boots at all:         yes: the framework reported the machine running after 0.4 s
boot time:            0.3 s from booting to running (...)
dry run:              the configuration validated
```

and under `start:` an exit status of 0 and no `refused` line. A guest that never writes to its serial console is normal for
an installer ISO (the report says `the guest wrote nothing to its console`); the claim is only that the framework reported
the machine running.

Report, for each of the five runs, the whole text the command printed, and whether a window or a prompt appeared. If the
machine did not start, the report already names the failing step (`no: the machine failed to start: ...`) and lists the
sandbox denials, whose Mach-lookup names are what the profile is missing. Also report `ls ~/Library/Containers | grep
VMHelper` and whether `~/sandbox-run/efi.nvram` exists afterwards. To clean up:
`rm -rf build/sandbox ~/sandbox-run ~/Library/Containers/com.example.VMRunner.VMHelper`.

Reading the result: five times `yes` means both engines carry a headless machine, and the roadmap entry can move on to the
settings model. A failure under `seatbelt` only means the profile misses a Mach service or a file rule, which the denials
name. A failure under `app-sandbox` that the denials do not explain would mean the framework needs something an App Sandbox
helper cannot be given, which would leave `seatbelt` as the only engine for helpers.

## The console socket (2026-10-22)

The descriptor gained `console: { "socket": PATH }`: the helper attaches the guest's first serial port to one end of a socket
pair, serves the other end on a local socket (`GuestConsole`), and reports `consoleReady` with the path before `booting`. The
probe has a check for it, `listen on the console socket`, which binds and listens on the path and lets go. Run without a
machine (`--probe`), on this host, with the socket in a 0700 directory under `/tmp`:

- **Seatbelt:** with no grant the probe cannot even look at the directory (`file-read-metadata`, which the bridge needs to
  check that it is private). Granted the path itself (`file-read-metadata file-write*` on the one `literal`) plus the
  directories above it, the probe listens. Taking out the two socket rules (`network-bind` and `network-inbound`, each for
  the one `path-literal`) did **not** change the probe: binding a local socket is checked as a file creation. They stay in
  the profile for accepting a connection, which only a booted guest with a client can show; that is **not verified** here.
  Taking out the file rule made `bind` fail with `Operation not permitted`.
- **App Sandbox:** refused, `bind: Operation not permitted`, and the log names `file-write-create` on the path. Adding the
  path as an `absolute-path.read-write` exception moved the denial to `network-bind` on the path; adding
  `com.apple.security.network.server` as well did not clear it. So an App Sandbox helper cannot serve a console on a path
  outside its container with the entitlements tried, and the generated entitlements are left as they were. A socket inside
  the helper's container was not tried. Run `vmr sandbox run --engine app-sandbox` with a console descriptor to see the
  refusal; starting such a helper ends with `cannot serve the console on <path>`.

## Not verified

Everything about a machine that is actually running inside either engine (the owner's run above): the Mach services and file
rules the framework needs once a machine starts, whether the framework issues the sandbox extensions as inferred, NAT inside
either engine, and boot time. Also: the user-mode network stack hosted in a helper (it was not extracted from the app), a
security-scoped bookmark or a container-staged disk as the App Sandbox file mechanism, `network.server` for binding to a port
(for a local socket it was tried and did not help, see above), whether
an ad-hoc re-signed helper bundle can be launched by a notarized app, and the wording of a later Apple engineer comment about
the macOS 27 descendants client.

## Boot run results (2026-10-22)

The owner's boot run above was done under the owner's authorisation on the host of the probe results (Mac15,12, Apple M3,
macOS 26.7.1), with a scratch directory under `/tmp`, two CPUs and 2048 MiB per guest, no window opened and no GUI driven.
Commands were the documented five (`vmr sandbox run --engine ... --descriptor ... --boot --run-seconds 40`), run with the
already built `vmr` binary because a container build held the package lock; the report text is the tool's own.

**Image.** Alpine 3.24.2 `virt` for aarch64 (93,304,832 bytes), the newest release with an `.asc`: 3.24.3 is listed on the
mirror with `.iso`, `.sha256` and `.sha512` but its `.asc` answers 404. SHA-256 `a57ba668...bf43dbf6` matched the published
file, and `gpg --verify` against `ncopa.asc` from alpinelinux.org/keys reported a good signature by the key
`0482D84022F52DF1C4E7CD43293ACD0907D9495A` (the key is not in a web of trust, as gpg says).

### The five documented runs (EFI boot of the ISO)

| Run | Boots | Booting to running | Start phase | Denials in the start phase |
|---|---|---|---|---|
| `none`, file-handle NIC | yes | 0.193 s (0.213 s from the helper's start) | exit 0, 42.6 s | none |
| `seatbelt`, file-handle NIC, as shipped | **no**: "Invalid virtual machine configuration. The boot loader is invalid." | - | exit 70 after 0.15 s | 36 in the run, see below |
| `seatbelt`, file-handle NIC, `hw.pagesize_compat` allowed | yes | 0.090 s (0.101 s) | exit 0, 40.1 s | 3: `/dev/dtracehelper`, the `syslog` socket, `mach-task-name` of the machine service |
| `app-sandbox`, file-handle NIC | yes | 0.080 s (0.090 s) | exit 0, 40.1 s | none |
| `seatbelt`, NAT | yes | 0.083 s (0.094 s) | exit 0, 40.2 s | the same 3 |
| `app-sandbox`, NAT | yes | 0.081 s (0.091 s) | exit 0, 40.2 s | none |

Every run printed `the guest wrote nothing to its console`: the ISO's boot loader does not use the virtio console, so these
runs prove only that the framework reported a running machine (and that firmware ran: `efi.nvram`, 131,072 bytes, was
written). The helper has no user interface code, so no window or prompt is expected; the screen was not watched. `~/Library/Containers/com.example.VMRunner.VMHelper`
appeared with the first App Sandbox run (32 KB) and `efi.nvram` exists afterwards.

### A guest that talks: kernel boot from the same ISO

To see the guest run, the kernel and initial ramdisk were taken out of the verified ISO (`boot/vmlinuz-virt` is an EFI
"zboot" image; its gzip payload is the arm64 `Image` the framework's Linux loader takes) and started with the descriptor's
kernel boot and `console=hvc0`. Every run below ended with Alpine's `localhost login:` prompt (152 console lines, `Linux
6.18.52-0-virt (aarch64)`), exit status 0, a 40.1 to 40.3 s start phase.

| Engine, level, network | Booting to running | First console line, after booting |
|---|---|---|
| `none`, standard, file-handle | 0.099 s | 0.204 s |
| `seatbelt`, standard, file-handle | 0.089 s | 0.186 s |
| `seatbelt`, strict, file-handle | 0.087 s | 0.192 s |
| `seatbelt`, standard, NAT | 0.090 s | 0.192 s |
| `app-sandbox`, standard, file-handle | 0.096 s | 0.199 s |
| `app-sandbox`, strict, file-handle | 0.175 s | 0.406 s |
| `app-sandbox`, standard, NAT | 0.090 s | 0.192 s |

The first console line is Alpine's initramfs (`Alpine Init 3.14.1-r0`). With `ip=dhcp` on the command line and the NAT
attachment, the guest got a lease (`udhcpc: lease of 192.168.64.x obtained from 192.168.64.1`) at 2.95 s of guest time with no
sandbox, 2.94 s under Seatbelt and 2.90 s under App Sandbox: NAT is provided by the framework's own service and needs
nothing from the helper's sandbox in either engine. The file-handle NIC is attached to a socket pair that nothing serves, so
a guest network through the user-mode stack in a helper is still untested.

### What the helper itself could do inside the sandbox (its probe)

| Operation | none | Seatbelt standard, file-handle | App Sandbox standard, file-handle | strict, or NAT (either engine) |
|---|---|---|---|---|
| connect TCP, send UDP, ICMP echo socket | allowed | allowed | allowed | refused |
| resolve `example.com` | allowed | allowed | allowed | refused |
| `/etc/hosts`, resolve `localhost` | allowed | allowed | allowed | Seatbelt refuses both; App Sandbox allows both |
| bind a UDP socket on loopback | allowed | refused | refused | refused |
| home directory, a new file in `/private/tmp` | allowed | refused | refused | refused |

The host sockets of the standard level exist only when the helper hosts the network (file-handle). A NAT descriptor at the
standard level gets the strict column, which is intended: the framework's service does the NAT.

### The one missing rule, and how it was found

Under the profile as shipped the start failed in 0.15 s with the "boot loader is invalid" error although `validate()` passed. The
log held, for the start, `sysctl-read hw.pagesize_compat`; `file-read-data` of the helper's own directory (3x);
`mach-lookup com.apple.system.opendirectoryd.libinfo` with `file-read-data` and `file-read-metadata` of `/private/etc/passwd`
(6x each); `mach-task-name` of the machine service; `/dev/dtracehelper`; the `syslog` socket. The helper was then run by
hand under copies of the profile, one rule added at a time, three seconds each:

| Added to the profile | Start |
|---|---|
| `(allow mach-task-name)` | fails, same error |
| `(allow file-issue-extension)` | fails |
| `libinfo` Mach lookup and `/private/etc/passwd` | fails |
| read of the helper's directory | fails |
| `(sysctl-name "hw.pagesize_compat")` alone | **runs** |
| all five together | runs |

So the only rule added to the generator is `hw.pagesize_compat` (commit "Let the Seatbelt profile read hw.pagesize_compat",
with a test). The other denials stay denied: a machine runs without them. Removing the Mach lookup of
`com.apple.Virtualization.VirtualMachine`, which the generator had listed as a guess, fails the start ("Internal
Virtualization error. The virtual machine failed to start.") with `deny(1) mach-lookup
com.apple.Virtualization.VirtualMachine (xpc)` in the log, so it is confirmed and needed. The framework's other lookups
found earlier (`diskimagescontroller`, `logd`, `notification_center`) stayed in the list and the machines started; each was
found by a denial in the previous round, and none was re-tested by removal. The framework also logs that it falls back to
direct preferences access ("Update your sandbox profile to allow cfprefsd access!"); the machine starts regardless, so no
rule was added for it.

### Answers to the open questions

- **Does a machine boot inside either engine?** Yes, both, at both levels, with NAT and with the file-handle NIC, headless.
  Seatbelt needed the one sysctl above. App Sandbox needed no more than the entitlements the helper bundle already has (the
  path exceptions, `virtualization`, and `network.client` at standard).
- **Which Mach services does a boot need?** `com.apple.Virtualization.VirtualMachine` (the per-machine service),
  `com.apple.diskimagescontroller`, `com.apple.logd`, `com.apple.system.notification_center`; no other Mach lookup was logged as
  denied during a start (the log undercounts, but the machines started).
- **Boot time.** The framework reports a running machine 0.08 to 0.2 s after `booting` in every engine (App Sandbox strict was the
  slowest, 0.175 s in one run); a guest's first console line follows about 0.1 s later; the guest's own clock shows its network up
  at about 2.9 s. No engine is measurably slower in these single runs; the differences are within what repeated runs of the
  `none` control would show (not measured).
- **Does the model hold?** Yes: see ADR-0016, now accepted. The three engines are renderings of the same grants, and the two
  levels are the host-socket switch.

### Still not verified

The user-mode network stack hosted in a helper (it was not extracted from the app); `network.server` for binding; a
security-scoped bookmark or container-staged disk as the App Sandbox file mechanism; a notarized app launching an ad-hoc
re-signed helper; the `custom` level; repeated runs for a spread of boot times; whether the unified log's throttling hid a
denial in any run (the machines started, so no missing rule was left unexplained); any run longer than 40 s.
