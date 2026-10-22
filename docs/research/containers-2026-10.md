---
date: 2026-10-21
question: "Can Apple's container primitives run OCI images in the app, and what can a macOS container be?"
feeds: [roadmap 0024, ADR-0017]
---
# Containers, OCI images, and macOS "containers"

Study, not a decision record. Facts come from the projects' sources and documentation as of 2026-10-21. Items marked
*unverified* were not confirmed.

## Short answer

- Apple's real container primitive is the **containerization** package (Apache-2.0): one lightweight Linux virtual machine
  per container, OCI image handling in Swift, usable as a SwiftPM dependency. VMRunner can pull and run an arm64 Linux image
  in-process.
- Apple has **no macOS container**. The honest equivalent is a macOS virtual machine cloned from a pulled base image and
  started from a saved state, bounded by the two-VM limit and the macOS licence.
- Containers and virtual machines can share one `Workload` abstraction with capability flags, one APFS clone service and
  one network-policy engine.

## Apple's pieces

**containerization** (Swift package; tools 6.2; the README requires an Apple silicon Mac on macOS 26).
- Products: `Containerization`, `ContainerizationOCI`, `ContainerizationEXT4`, `ContainerizationNetlink`,
  `ContainerizationIO`, `ContainerizationOS`, `ContainerizationExtras`, `ContainerizationArchive`, the in-guest init
  (`vminitd`) and the `cctl` sample tool.
- **Images:** an image store actor pulls, pushes, tags, lists and deletes images, selects a platform, and saves or loads
  OCI layouts. A content store is a local OCI layout. Layers are unpacked to a per-container `rootfs.ext4`, copied with
  `clonefile` on macOS, which gives APFS copy-on-write for root filesystems.
- **Registries:** credentials come from the Keychain (`lookup`, `save`, `delete`); any authentication object can be passed
  to a pull. Docker Hub, GHCR and Quay work with it. For ECR, GCR and ACR the short-lived token must be supplied as the
  password; the token flow was *unverified*.
- **Running:** create, start, stop, kill with a signal, wait, resize, exec, dial a vsock port, statistics, copy in and out.
  Configuration covers CPUs, memory, mounts (virtiofs shares and block devices), sockets, DNS, hosts, sysctls, masked and
  read-only paths and capabilities. Seccomp needs an OCI runtime.
- **Networking:** three attachment types exist. vmnet-based networks need macOS 26 and a vmnet entitlement; a plain NAT
  attachment works on older systems; and the interface protocol returns a `VZVirtioNetworkDeviceConfiguration`.
  *Inference, to be confirmed by the first run:* a custom interface backed by a file-handle attachment would let containers use
  VMRunner's user-mode stack and its allow and deny lists. The in-guest init configures a static address from the
  interface, so the stack must hand out the same one.
- **Entitlements:** Apple's own signing files grant only `com.apple.security.virtualization`, and the helpers are signed
  ad hoc. A sandboxed or App Store build of a vmnet user is *unverified*.
- **Kernel:** the caller supplies one. Tests start at Linux 6.14.9 with virtio built in; the Kata Containers kernel works,
  and the CLI's default is a pinned Kata release. The init image is pulled from Apple's registry.
- **Security note:** a recent release advisory concerns pulling by digest without verifying the digest the registry
  returned. Pin a release that includes the fix: 0.52.1 is the first one (verified on 2026-10-22, see the runner section).

**container** (the command line and daemon built on it; macOS 26 only).
- An API server launch agent starts XPC helpers: an image service, a vmnet network service and one runtime helper per
  container. It installs to `/usr/local` from a package that needs administrator rights.
- Builds run BuildKit in a builder virtual machine, with multi-platform `--arch`. It also has volumes, networks, registry
  login, JSON output on list and inspect commands, full-init Linux "machines" and an experimental Kubernetes command. It has
  no compose.
- Only the XPC API is compatible within a major version; other helpers are not.

**Embed or drive?** Embed the library for pulling and running. Delegate Dockerfile builds to the command line as an optional
"Builder" capability, so the app does not need the daemon for everything else.

## macOS "containers"

- **Apple's position:** the project "focuses on Linux based container workloads". macOS has no namespaces or cgroups
  (*inference; no primary source*). App Sandbox, Seatbelt, `chroot` and launchd are weaker tools, not container isolation.
- **Licence:** the macOS 26 licence allows up to two additional instances in virtual environments on each Apple computer for
  software development, testing during development, macOS Server, or personal non-commercial use, and excludes
  time-sharing and hosted services. The macOS 27 text was not checked. The framework reports the limit as
  `VZErrorVirtualMachineLimitExceeded`; the number two comes from the licence, not from a header.
- **Distribution of macOS images as OCI artifacts** is done by existing tools with a custom manifest and media types: a
  config blob, an NVRAM blob and a disk split into chunks of at most 512 MiB, each LZ4-compressed with its uncompressed size
  in an annotation; zero-filled 4 MiB runs are skipped on pull to stay sparse; a local layer cache deduplicates. Base images
  sit in public registries. That tool's licence has a competing-use clause, so **do not copy or link its code**; read only
  the public format, and take legal advice before shipping anything compatible.
- **An image store inside VMRunner is feasible** as a custom OCI artifact with our own media types, carried by the
  containerization registry client (*arbitrary media types: unverified*). On macOS 26, a raw disk image is not
  sparse-aware, so clone on pull and keep a chunk-digest index for deduplication. macOS 27's stacked ASIF images allow a
  shared read-only base with a writable overlay; the auxiliary storage and the EFI variable store still need copying per
  clone.
- **What it honestly means:** a disposable macOS VM, cloned from a pulled base and restored from a saved state, in seconds
  only when restoring, not when booting cold. The saved state must come from the same host and OS. First-boot provisioning
  needs a macOS 27 guest and applies once, so provision, then snapshot.
- **Limits:** two macOS VMs per host, development and personal use only, no Rosetta (Linux guests only), no hosted
  multi-tenant service.

## Feature parity

F = feasible, P = partial, N = not feasible. "Container" is a Linux container on containerization; "macOS container" is the
cloned macOS VM.

| Feature | Container | macOS VM | Linux VM | macOS container |
|---|---|---|---|---|
| Display sizing, full screen | N: headless | F | F | F |
| Security presets | F: capabilities, read-only root, masked paths, mounts | F | F | F |
| APFS copy-on-write (images, snapshots, disposable) | F: clone of the root filesystem | F | F | F |
| Egress allow and deny: IP, port, connection, domain | P: custom interface on the user-mode stack (inferred); vmnet has no filter | F | F | F |
| Egress by URL | P: needs a TLS-intercepting proxy | P | P | P |
| VPN detection, host side | F | F | F | F |
| VPN detection, inside the guest | P: exec plus a route listing | P: agent | P: agent | P |
| Guest follows the host's network | P: only with the user-mode stack | F with it | F with it | F with it |
| Host-information forwarding | P: agent over vsock; no battery device in the SDK | P | P | P |
| "Hide that it is a VM" | N | N | P | N |
| Managed preferences, host side | F | F | F | F |
| MDM, guest side | N | P (unverified) | N | P (unverified) |
| 3D / GPU | N: no GPU device | P: paravirtualized Metal | N: not accelerated (unverified) | P |
| Install from ISO or OCI | OCI | IPSW or OCI-distributed disk | ISO F; OCI to bootable disk P | OCI artifact F |
| Unattended provisioning | F: environment, entrypoint, exec | F: macOS 27 options or SSH | F: cloud-init seed | F |
| Kubernetes-compatible provisioning | P: experimental in the CLI | N | N | N |
| MCP, CLI, terminal automation | F: exec and streams | F: agent or SSH | F | F |
| Screenshots, recording | N | F | F | F |
| Shared folders | F: virtiofs | F | F | F |
| Suspend and resume | P: not exposed by the library | F | P (unverified) | F |

## Architecture

A `Workload` protocol with `.vm(linux | macOS)` and `.container(linux)`; the cloned macOS VM is a policy-flagged variant of
the macOS VM, not a fourth kind. Shared contract: lifecycle, exec and streams, mounts, network policy, snapshots and an
optional display. A feature a kind lacks is a **capability flag the interface reads**, not a stub that fails at run time.
One clone service and one policy engine serve every kind.

Depend on the containerization package, pinned exactly (and the three library products only); drive the command line only for
builds.

## Plan

1. **First run (low risk):** a macOS 26 target with the virtualization entitlement and no sandbox. Mirror the sample tool's run
   flow: a kernel, a container manager with the init image, pull `alpine`, create, start, wait. Pass when `uname -a` prints
   `aarch64` and the exit status comes back. Fetching a kernel and the init image is the main setup cost.
2. Route container networking through the user-mode stack (medium).
3. An OCI image store with clone-on-pull for macOS VMs (medium).
4. macOS 27 provisioning and stacked ASIF overlays (medium).
5. Optional command-line builds and Kubernetes (low value).

## Do not

- Copy or link code from a project whose licence forbids competing use.
- Promise Docker compatibility, compose, more than two macOS VMs, or hosted multi-tenant macOS.
- Claim that hiding virtualization works against a determined analyst.
- Depend on private XPC helpers across versions, or on the daemon's state directories.
- Build a kernel pipeline in the first version.

## Not verified

The installed `container` version on this machine (the tool could not be run in the study), vmnet behaviour in a sandboxed or
App Store build, the cloud registries' token flows, the macOS 27 licence text, Linux-guest GPU limits, suspend and resume
under the library's device set, and arbitrary artifact media types in its registry client. The runner section below adds what
was and was not verified for the runner itself.

## The container runner (2026-10-22)

The runner of the plan's first step is written, builds and is tested without a guest. Nothing in it has booted a virtual
machine: the owner runs it once, from the instructions below, and the result decides whether ADR-0017 stands.

### What was checked on the network

- **Releases.** The project publishes git tags, not GitHub releases (its release list holds three old pre-releases). The
  newest tag is 0.53.0, which is 0.52.1 plus one commit (platform introspection in the image store).
- **The digest advisory** is GHSA-vgrw-36j7-r93w, published 2026-10-20, medium: a pull by digest trusted the digest the
  registry returned instead of the pinned one. Its text names change 973, "released in 0.52.1". The tag 0.52.1 is that
  change's merge commit and 0.52.0 does not contain it, so **0.52.1 is the first fixed release and is the pin**. The
  advisory's machine-readable range says "<= 0.52.1" with patched version 0.52.1, which contradicts itself; the text and the
  tags decide. Ten other advisories in the project's list have fixes in 0.42.0 or earlier (content store path traversal,
  registry realm validation, container id deletion, layer unpacking crashes, symlinks in image layouts, and more), so 0.52.1
  carries them too. The study was right that a recent advisory exists; only the fixing release was unknown.
- **Requirements of 0.52.1.** Tools version 6.2 (the repository uses 6.4), declared macOS 15 (the repository 26; the README
  asks for macOS 26 on an Apple silicon Mac), Apache-2.0.
- **Dependency graph.** The package brings 24 others with it, 29 pins in all: an asynchronous networking stack, an RPC stack
  with its serialization library, an HTTP client, TLS and certificate libraries, a crypto library, a compression library and
  logging, tracing and configuration libraries. It also links the system archive library. ADR-0001 keeps the root graph
  small, so the runner is a package of its own, `Packages/Containers`, with its own committed `Package.resolved`: the root
  `Package.swift` and `Package.resolved` are unchanged, nothing at the root depends on the package, and a test checks both.
  The gate reaches it through the `packages` key of `.vmr.json`: `vmr check build` and `vmr check test` also build and test
  it, each into `.build-packages/Packages-Containers`, from its `Package.resolved` alone.
- **Kernel.** The package's own `fetch-default-kernel` target takes Kata Containers 3.17.0 for arm64
  (`kata-static-3.17.0-arm64.tar.xz`, 290,581,648 bytes, the size GitHub reports). The release publishes no checksum, so the
  SHA-256 `647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181` was computed from a download made for the runner
  (trust on first use, like a lock file). The archive's `vmlinux.container` is a link; the runner unpacks the file it points
  to, `vmlinux-6.12.28-153` (SHA-256 `67bac9f416af4cdc9b151e4ba4962d6515e0ad7acc53816761cf964aa6af6ea0`), and checks both.
  **Linux 6.12.28 is older than the 6.14.9 the package says it tests from.** The package's newer example tool takes a later
  Kata release (3.26.0, a `.tar.zst`); if 6.12.28 fails to boot with this init image, that is the first thing to try.
- **Init image.** `ghcr.io/apple/containerization/vminit:0.52.1` exists (index digest
  `sha256:4679ea8d80dde436c847de4c7c08425de40bb50b0e744e917160e29a039a6195` on 2026-10-21). The runner pulls it by tag, matched
  to the pinned package because the host and the guest speak a versioned protocol.
- **Image.** `alpine:3.24.2` from Docker Hub, pulled for `linux/arm64` only.

### What compiled

- `Packages/Containers/Sources/ContainerRunnerCore`: arguments, the layout under the scratch directory, the pinned kernel
  archive and its checksum, the verdict and report, an Ethernet frame summary, and a datagram socketpair that stands in for a
  network. It imports no container library; `Packages/Containers/Tests/ContainerRunnerTests` has 24 tests of it.
- `Packages/Containers/Sources/ContainerRunner`: downloads and checks the kernel, builds a container manager, pulls the image, creates the
  container, boots it, runs `uname -a`, waits, stops and deletes it, and prints the report. Everything is under the scratch
  directory given as the argument. The kernel download is one fixed HTTPS address checked against a pinned checksum; it does
  not go through the app's download policy, which the runner cannot import.
- `vmr container-sign`: builds the runner from its package (release by default, into the scratch directory the gate uses) and
  signs it ad hoc with the hardened runtime and `Resources/ContainerRunner.entitlements`
  (`com.apple.security.virtualization` only, judged against the entitlement policy), then verifies the signature and reads
  the effective entitlements back. It shares those steps with `vmr build-app` and the sandbox helper.
- The `packages` key of `.vmr.json` in `vmr`, with tests against a fixture package (a pass, a failing test, a build error, a
  missing manifest, the path rules), and a test that the nested package's safety settings are a verbatim copy of the root's.

### What was verified without a guest

- The whole gate (`swift run vmr check --full`, 13 steps, 17 minutes with warm caches) passes with the package present:
  format, SwiftLint, documentation, policy, build and test (the root and `Packages/Containers`), the three analyzers, the
  address, thread and undefined-behaviour sanitizer runs, the release build, the coverage gate and the benchmark gate, with
  no baseline change. The analyzers also print their existing warnings and notes; none is new. The sanitizer, release and
  coverage steps cover the root package only.
- Signing: four tests sign a copy of a system executable and read the result back with `codesign`, one builds a fixture
  package of its own into its scratch directory and signs the result, and one checks the entitlements file. A real
  `swift run vmr container-sign` built the release runner from `Packages/Containers` (695 s cold on one machine, including
  `vmr` itself; 910 s of CPU) and signed it; the signed binary starts and prints its usage under the hardened runtime. It
  lands in `.build-packages/Packages-Containers/release/ContainerRunner`.
- **The root build does not change.** The root `Package.swift` and `Package.resolved` are identical to main's apart from two
  comment lines that mark the shared safety settings, and a test checks that the root names neither the package nor its
  library. A clean `swift build --product VMRunner` into an empty scratch directory took 63.4 s on this branch and 74.0 s on
  unmodified main (user CPU 65.3 s and 65.0 s; five packages fetched in both). What grows is `vmr check build`, which now
  also builds the nested package, and the first signing.
- The three analyzers look only at `Sources` and `Tests`, so they do not see the nested package; run by hand on its sources
  and tests they report no finding. Making the gate look there needs a root list in the analyzer service, which is not a
  one-line change.
- With a temporary hook that was not committed, the runner ran everything up to, and excluding, the boot: the kernel download,
  both checksums and the unpacking; the init image pull and init block (14.3 s cold); the arm64 alpine pull (3.6 s cold);
  unpacking the image to a root filesystem and creating the container object (8.3 s); the cleanup. A second run reused the
  caches (0 s, 0.9 s, 2.2 s), and a kernel with one byte appended was refused and removed. These are debug-build timings on one
  machine and are not the figures the first run reports.
- With the same kind of hook, the loopback network handed out its interface (198.18.0.2/24, gateway 198.18.0.1), the interface
  produced a virtualization network device configuration with a file-handle attachment, a second interface was refused, and a
  frame written to the guest end of the pair was read on the host end. The unit tests cover a frame above the 2 KiB default of
  a local datagram socket (the link raises the buffers) and the end of the reader.

### Second check: the user-mode stack

The container library lets a network hand out interfaces that also say how to build their virtual device, so a container can
get a device backed by a file-handle attachment, which is how the app attaches a guest in its filtered mode. `--network
loopback` does exactly that on a socketpair read by the runner, with the stack's address plan (guest 198.18.0.2/24, gateway
198.18.0.1). The container pings the gateway and the runner reports the frames its device delivered; an ARP request for the
gateway is the pass.

The real stack is not plugged in because it lives in the app target, which cannot be imported without linking the app (its
views, its settings, its other package). Extracting it was out of scope. **What would be needed**, checked by compiling the
files in a scratch package with the repository's compiler flags and no source change:

1. A library target for the stack: the 50 files of `Sources/VMRunner/Network`, eight model files (`IPAddress`,
   `NetworkHost`, `NetworkPolicy`, `NetworkRules`, `NetworkPortRules`, `FlowLog`, `Log`, `StringRuleCoding`) and
   `Engine/VPNMonitor.swift`: 59 files, about 7,400 lines, no external package. ADR-0001 holds, because the app would link
   one more module of its own.
2. Access: everything is internal today. The runner needs `UserNetStack.attachment(config:policy:)`, `start()`, `stop()`,
   `UserNetConfig` and `NetworkPolicy`; SwiftPM's `package` access level would expose them to the app and the runner without
   making them public.
3. The stack's tests (`UserNet*`, `Network*`, the VPN tests in `Tests/VMRunnerTests`) use `@testable import VMRunner` and
   would move to a test target of the new module. The coverage ignore pattern in `.vmr.json` and the sanitizer trigger in
   `ci.yml` both name `Sources/VMRunner/Network` and `Engine` by path and would follow the files.
4. The runner's package would need the module. The root package would have to export it as a library product and
   `Packages/Containers` depend on the root by path, which adds the root's own packages to the nested graph's resolution
   (they are not linked); or the stack becomes a package of its own that both depend on, which keeps the two graphs apart.
5. In the runner, `LoopbackLink` is replaced by the stack's attachment: start the stack before the container boots, stop it
   after, and give the interface the stack's guest address and gateway (already the runner's). The container library
   configures a static address and never asks for DHCP, so the stack's DHCP server would go unused.

### First run

Needs an Apple silicon Mac on macOS 26 or later, about 600 MB of free disk space and network access to GitHub and two
registries. It needs no administrator rights and installs nothing outside the checkout's `.build-packages` and the scratch
directory. Run it in a normal Terminal window, not from an agent.

```sh
swift run vmr container-sign
```

This builds the release runner (about eleven minutes the first time on the machine used here; the container package's graph is
compiled) and ends with `entitlements OK (com.apple.security.virtualization)` and `Signed <path>`. The binary is
`.build-packages/Packages-Containers/release/ContainerRunner`.

```sh
.build-packages/Packages-Containers/release/ContainerRunner ~/ContainerRunnerScratch
```

The first run downloads the 290 MB kernel archive, so it takes a few minutes. Expected output, with your own numbers:

```
scratch: /Users/you/ContainerRunnerScratch
kernel: .../kernel/vmlinux (unpacked, checksum ok)
init-image-seconds: 14.30
pull-seconds: 3.59
create-seconds: 8.30
boot-seconds: ...
run-seconds: ...
output: Linux <name> 6.12.28 ... aarch64 Linux
exit-status: 0
verdict: passed
```

The command exits 0 on a pass, 1 when the container ran and the result was wrong (a non-zero exit status or no `aarch64`),
70 when something before or around it failed (download, checksum, pull, boot), and 64 for a bad command line. When the boot
or the run fails, the container directory stays and its boot log is at `<scratch>/store/containers/<id>/bootlog.log`; the
path is printed to standard error.

Then the second check, with the same scratch directory (everything is cached):

```sh
.build-packages/Packages-Containers/release/ContainerRunner --network loopback ~/ContainerRunnerScratch
```

It adds `frames-seen: N`, up to 20 lines `frame: <source> -> <destination>, <length> bytes, <what>` and
`network-verdict: passed`. A pass shows `ARP who-has 198.18.0.1 tell 198.18.0.2`. The ping itself gets no reply, and the
shell ends with status 0 on purpose.

Remove the scratch directory afterwards.

**Report back:** the complete output of both runs; `init-image-seconds`, `pull-seconds`, `create-seconds`, `boot-seconds` (the
virtual machine start up to the guest agent being ready) and `run-seconds`; the `uname -a` line; the exit status; any error
text and the boot log if there was one; `sw_vers -productVersion` and the Mac's model.

**Questions the run answers**

1. Does a virtual machine start with only the virtualization entitlement, under an ad-hoc signature with the hardened
   runtime, and no vmnet entitlement? (A missing entitlement shows as an error naming `com.apple.security.virtualization`.)
2. Do the pinned kernel (Linux 6.12.28, below the tested floor) and the init image 0.52.1 work together?
3. What do the pulls and the boot cost cold, and what does `run-seconds` say about starting a process in a booted guest?
4. Does `uname -a` print `aarch64`, and does the exit status come back to the host?
5. Does a custom interface backed by a file-handle attachment deliver the guest's frames to the host, and does the guest
   accept the static address without a DHCP server?
6. Is anything in the run outside the scratch directory?

### Not verified by the runner work

That a virtual machine boots at all with these pins; the figures for the boot and the run; the behaviour of the hardened
runtime with the library under a real run; the loopback network with a real guest; the CI workflows with the new package
(the same commands pass locally, but the hosted runners were not tried, and the build lane compiles the package's graph on
every run until `.build-packages` is cached); the licences of the 24 packages the library brings in (nothing is shipped, but
an inventory is due before the app links any of them).

## First run results (2026-10-22)

The first run of the runner was done under the owner's authorisation, on a Mac15,12 (Apple M3) with macOS 26.7.1 (`sw_vers`),
with a scratch directory under `/tmp`, no administrator rights and no window. The container was capped by the runner itself at
two CPUs and 512 MiB (plus the framework's overhead). `swift run vmr container-sign` built the release runner (the cold build,
compiling the container package's graph, took about eight minutes on a busy machine) and ended with `entitlements OK
(com.apple.security.virtualization)` and `Signed ...`.

**The kernel pinned in the study worked; the fallback was not needed.** Kata 3.17.0 (Linux 6.12.28) and the init image 0.52.1
booted a container on the first try, so the pin and the tests are unchanged. The newer Kata release (3.26.0) was not tried.

First run, empty scratch directory:

```
kernel: downloading https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz
kernel: /tmp/.../kernel/vmlinux (unpacked, checksum ok)
init-image-seconds: 13.48
pull-seconds: 3.28
create-seconds: 0.06
boot-seconds: 0.27
run-seconds: 0.05
output: Linux runner-cbcf2e6c 6.12.28 #1 SMP Tue May 20 15:19:05 UTC 2025 aarch64 Linux
exit-status: 0
verdict: passed
```

A second cold run (scratch directory removed, same machine) gave 13.20, 2.98, 0.05, 0.29 and 0.05 s, and took 70 s wall clock
in all, so the kernel download and unpacking (290 MB over the network, then a 14 MB kernel) cost about 53 s of it. Both runs
exit 0. The `--network loopback` run, with everything cached (4 s wall clock), gave `init-image-seconds: 0.00`, `pull-seconds:
0.87`, `create-seconds: 0.05`, `boot-seconds: 0.28`, `run-seconds: 2.04` (this one runs a ping as well), `exit-status: 0`,
`verdict: passed`, `frames-seen: 7` and `network-verdict: passed`; the frames were `ARP who-has 198.18.0.1 tell 198.18.0.2` (twice) and
five IPv6 neighbour and multicast frames from the guest's MAC address. These are release-build figures; the debug-build
figures of the section above (8.3 s to create) were not reproduced, the same step took 0.05 s.

### The six questions

1. **A virtual machine starts with only the virtualization entitlement**, under an ad-hoc signature with the hardened runtime
   and no vmnet entitlement: yes. No error named an entitlement.
2. **The pinned kernel (6.12.28) and the init image 0.52.1 work together**: yes. The guest reports `6.12.28`.
3. **Cost, cold:** init image 13.2 to 13.5 s, alpine pull 3.0 to 3.3 s, create 0.05 s, boot to a ready guest agent 0.27 to
   0.29 s, starting `uname -a` in the booted guest 0.05 s; the one-off kernel download dominates a first run (about 53 s here).
4. **`uname -a` prints `aarch64`, and the exit status returns to the host**: yes (`exit-status: 0`, the runner's own exit
   status 0, verdict `passed`).
5. **A custom interface on a file-handle attachment delivers the guest's frames to the host**: yes (seven frames in the loopback
   run), **and the guest accepts the static address without a DHCP server**: the ARP request names 198.18.0.2 as the sender,
   and the guest sent no DHCP request among the frames (all seven were listed; the runner prints up to 20).
6. **Anything outside the scratch directory: one thing.** `~/Library/Caches/ContainerRunner` (80 KB: `Cache.db`, its journal
   and an empty `fsCachedData`), the default URL cache of the kernel download, which uses the shared URL session. It was removed
   afterwards. The runner's scratch directory itself held 532 MB (277 MB of downloads, 14 MB of kernel, 241 MB of image store),
   and no container directory was left after a pass. The documented claim that the runner installs nothing outside the checkout and the scratch
   directory was therefore false by one cache directory; a download session without a cache fixes it (a follow-up).

### What the run does not show

The real user-mode stack in place of the socketpair (the module split above is still due); a command that needs the network
from inside the guest; a pull with credentials; the Kata 3.26.0 kernel; the licences of the packages the library brings in;
the behaviour of the runner under a sandbox (App Sandbox or a Seatbelt profile); and any run longer than the few seconds
`uname -a` takes.
