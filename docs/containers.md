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
  *Inference, to be confirmed by a spike:* a custom interface backed by a file-handle attachment would let containers use
  VMRunner's user-mode stack and its allow and deny lists. The in-guest init configures a static address from the
  interface, so the stack must hand out the same one.
- **Entitlements:** Apple's own signing files grant only `com.apple.security.virtualization`, and the helpers are signed
  ad hoc. A sandboxed or App Store build of a vmnet user is *unverified*.
- **Kernel:** the caller supplies one. Tests start at Linux 6.14.9 with virtio built in; the Kata Containers kernel works,
  and the CLI's default is a pinned Kata release. The init image is pulled from Apple's registry.
- **Security note:** a recent release advisory concerns pulling by digest without verifying the digest the registry
  returned. Pin a release that includes the fix (*which release fixed it: unverified*).

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

1. **Spike (low risk):** a macOS 26 target with the virtualization entitlement and no sandbox. Mirror the sample tool's run
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
App Store build, the cloud registries' token flows, the release that fixed the digest advisory, the macOS 27 licence text,
Linux-guest GPU limits, suspend and resume under the library's device set, and arbitrary artifact media types in its registry
client.
