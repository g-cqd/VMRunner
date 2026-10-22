---
date: 2026-10-21
question: "How can AI agents and scripts control machines (MCP, CLI, terminal) with isolation?"
feeds: [roadmap 0005]
---
# Automation: a control service, an MCP server, a CLI, and a terminal into the guest

**Status: investigated and partly prototyped; the serial console is built (see "Built: the console", at the end), the
control service, MCP server, screenshots and input are not.** The goal is to let a person, a script, or an AI agent
see and drive VMs (state, screenshots, input, commands, recording) while keeping the VM isolated: nothing leaves it or
enters it unless it is configured to.

## What was measured here

A throwaway probe in a scratch copy of the app, on a running Linux VM (macOS 26.7.1, M3):

| Question | Result |
|---|---|
| Screenshot with AppKit (`cacheDisplay` of the `VZVirtualMachineView`) | **Blank (black)**. The view is Metal-backed; AppKit does not draw its content. |
| Screenshot with ScreenCaptureKit, current-process window capture (`SCShareableContent.currentProcess`, `SCScreenshotManager`) | **Works**; captured the real GRUB screen. No explicit Screen Recording prompt was observed in the test, which should be re-checked on a clean account. |
| Synthesized key events sent to the VM view (`keyDown`/`keyUp` with a Down-arrow key code) | **Delivered to the guest**: GRUB's highlight moved down one entry. |

Not measured: mouse input, recording, `SCRecordingOutput`, text entry through key events.

## Prior art

- An existing Virtualization.framework project ships screenshots, keyboard/mouse input, REST, MCP, and a CLI: a hidden
  window holds a `VZVirtualMachineView` and screenshots are PNG captures of it; its MCP input tool needs an explicit
  `--allow-write` flag ([FluxVM PR 214](https://github.com/zyvorai/zyvor-fluxvm/pull/214)). It notes captures go blank when
  the view's backing store is exactly the guest display size.
- Command execution without a network: Tart's guest agent runs commands over **vsock** (`tart exec`), with an exec wrapper
  that clients cannot disable and a fail-closed config ([tart-guest-agent](https://github.com/openai/tart-guest-agent)).
  A reported issue: output can be truncated on older guests (macOS 12–15) on a 26 host, so any protocol needs framing and
  length/checksum checks ([issue 1347](https://github.com/openai/tart/issues/1347)).
- Apple's own Containerization framework drives each VM through a guest init (`vminitd`) over gRPC on vsock
  ([apple/containerization](https://github.com/apple/containerization)).
- The official MCP Swift SDK ([swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)) supports stdio and a Streamable
  HTTP client; a server HTTP transport was added but its maturity should be checked before relying on it.

## Proposed architecture

**One in-app control service, thin front ends.**

1. **Control service** inside the app (it owns the VMs and the entitlement). JSON-RPC over a **Unix domain socket** with mode
   0600 in the user's private folder, peer-credential check, and optional per-client tokens.
2. **CLI** (`vmr`-style) and an **MCP stdio shim** that forward to the socket. stdio keeps the MCP surface reachable only by
   the client that launched it; if an HTTP transport is ever added it must bind to loopback, validate `Origin`/`Host`
   (DNS-rebinding), and authenticate, as the MCP spec requires ([security best practices](https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices):
   local-server compromise, scope minimisation).
3. **Per-machine agent access policy**, stored with the machine and part of the security profiles: which of *lifecycle*,
   *state*, *screenshot*, *input*, *exec*, *files*, *recording* an agent may use. Default **off**; Hardened keeps everything
   off. Dangerous operations ask for confirmation in the app (MCP elicitation where supported). Every call is audit-logged
   without secrets.

**Channels into the guest (each is a deliberate, configured door):**

| Need | Mechanism | Notes |
|---|---|---|
| State | in-process (`VZVirtualMachine.state`, config, exposure summary) | no guest involvement |
| Screenshot | ScreenCaptureKit current-process window capture, cropped to the VM view | `cacheDisplay` is blank |
| Keyboard | synthesized `NSEvent`s to the VM view (verified for keys) | mouse is expected to work the same; unverified |
| Terminal / commands, **no network needed** | `VZVirtioSocketDevice` + a small guest agent (exec with a PTY, stdio streams, exit code) | only guest-initiated connections to ports the host registered are accepted: default-deny |
| Console | `VZVirtioConsoleDeviceSerialPortConfiguration` bridged to a host PTY (Linux `hvc0`) | a raw byte pipe; protect it like a root shell |
| Files | a read-only inbox share and a separate outbox, or a framed transfer over vsock | smaller surface than a writable share |
| Recording | ScreenCaptureKit stream or `SCRecordingOutput` (macOS 15+), or frames from the same capture into `AVAssetWriter` | unverified here |

Because vsock and the console are host-mediated, an **air-gapped VM (network: None) can still be driven**, and nothing is
reachable from the network.

**Isolation properties to keep:** vsock is per VM (no shared address space between VMs); the host accepts only ports it
registered; sockets and PTYs are private to the user; the agent in the guest runs as an unprivileged user unless told
otherwise; every channel is a line in the exposure summary so the user can see what is open.

## Proposed MCP tools and resources (read-only first)

Tools: `list_machines`, `get_machine` (state, uptime, display size, exposures), `start`/`stop`/`pause`/`suspend`,
`snapshot_*`, `screenshot` (image content), `type_text`/`press_key`/`click`, `exec` (command, timeout, returns
stdout/stderr/exit code), `read_serial_log`, `put_file`/`get_file`, `record_start`/`record_stop`. Annotate tools with
read-only/destructive hints. Resources: `vm://<id>/screenshot`, `vm://<id>/state`, `vm://<id>/console-log`, with update
notifications.

## Suggested order

1. Control service plus a CLI: list, state, start/stop, screenshot.
2. MCP stdio shim over the same service.
3. Keyboard and mouse input, with the agent-access policy and audit log.
4. Serial console bridge.
5. Guest agent over vsock for `exec` (Linux first; a macOS agent needs its own installation story).
6. Recording.

## Risks and open questions

An agent with `exec` is a root-equivalent shell in the guest: the policy and confirmations are the control. Output
integrity over vsock needs framing. A screenshot-plus-input loop is slow and brittle compared with `exec`. ScreenCaptureKit
permissions and the blank-capture quirk need re-testing on macOS 27. (Everything above is as written on 2026-10-21; what
was built since is below.)

## Built: the console (2026-10-22)

The "Console" row of the channel table is built, as the first block of the control surface (roadmap 0005, ADR-0052): the
library `GuestConsole`, the helper's `console.socket`, the app's per-machine `serialConsole` switch and `vmr guest`. It was
run for real on an Apple M3, macOS 26.7.1, with other builds loading the machine (load average 8 to 15), a debug-built
helper, and the Alpine 3.24.2 aarch64 netboot image, 2 CPUs and 2048 MiB, NAT.

**What the guest needs.** Alpine's initramfs starts a getty on every `console=` device (`setup_inittab_console` in its
`init`): with `console=hvc0` on the kernel command line, `/etc/inittab` of the booted system holds
`hvc0::respawn:/sbin/getty -L 0 hvc0 vt100`, and root logs in with no password. `virtio_console` is built into the kernel,
so `hvc0` exists from the first line of boot. The netboot ramdisk builds its root file system in memory from a repository
(`alpine_repo=`, here the release's `main`) over the network (`ip=dhcp`), so the boot needs the NAT. The kernel the archive
ships (`vmlinuz-virt`) is an EFI zboot image holding a gzip-compressed kernel; the framework's Linux boot loader wants the raw
arm64 `Image`, which `vmr guest fetch` cuts out of the payload.

**Numbers** (every one from the runs of this session; the host was not quiet):

| What | Result |
|---|---|
| `fetch alpine-netboot`: 432 MB download, checksum, signature, unpack | 70 s; `sha256 OK`; `signature OK` by key 0482D84022F52DF1C4E7CD43293ACD0907D9495A; 3.24.3 passed over (no `.asc` yet) |
| Boot to a login prompt, from launching the helper (4 runs) | console socket ready 0.05 to 0.06 s; machine running 0.11 to 0.17 s; login prompt 9.76 to 10.21 s (a good part of it is the package install over NAT) |
| First command after boot, login included | 33 ms |
| 30 consecutive `exec` calls of `uname -r`, each a new process that connects, checks for a prompt and runs the command | 30 of 30 succeeded; min 38, median 45, mean 55, max 121 ms |
| 30 consecutive `exec` calls of `ip addr` (13 lines) | 30 of 30 succeeded; min 33, median 37, mean 37, max 43 ms |
| 2 MB of zeros as base64 (2,766,598 bytes) through the console | 1.19 s wall with the client's start-up; md5 equal to the guest's |
| 8 MB of random data as base64 (11,066,388 bytes) through the console | 2.98 s wall (about 3.7 MB/s, debug-built client); md5 equal to the guest's: nothing dropped or altered |
| A command that prints more than the client's 16 MiB limit | the client fails with `printed more than 16777216 bytes`; the next command works |
| A command that runs 30 s with `--timeout 3` | status 124 after 3.01 s; Ctrl-C is sent; the next command works |
| A second client while the first is attached | `vmr-console: busy: another client is attached`, then closed; `exec` retried 3.07 s and exited 125; the first client kept working |
| Helper killed with SIGKILL while a client is attached | the client saw the console close 12 ms later; the socket file is left, `exec` says nothing is serving it; the per-machine service was gone seconds later |
| `vmr guest stop` (SIGTERM) | helper gone in 66 ms |
| The same guest inside the Seatbelt helper (strict level, profile generated from its descriptor) | reached its login prompt; commands and `wget http://example.com` through NAT worked |

The commands the owner listed returned what they should: `uname -a` gave `Linux localhost 6.18.52-0-virt #1-Alpine SMP
PREEMPT_DYNAMIC 2026-09-15 05:37:48 aarch64 Linux`; `/proc/cpuinfo` showed two processors; `ip addr` an address
`192.168.64.x/24` on `eth0`; `ip route` a default route via `192.168.64.1`; `/etc/resolv.conf` `nameserver 192.168.64.1`;
`nslookup example.com` resolved to both address families; `wget -qO- http://example.com` returned the page.

**What the runs found** (each fixed; the first two by the real guest, the third by the stress runs of the unit tests): a
package install's progress bar (`7 79% ####...`) ended in `#` and was taken for a shell prompt, so `start` reported a prompt
six seconds into a ten second boot; a spawned helper inherits an ignored SIGTERM from a parent that ignores it (this
harness's shell does), so the launcher resets every signal to its default; and the client must set `SO_NOSIGPIPE` before
connecting, because once the console has refused it and closed, the option can no longer be set (EINVAL), which failed one
refused connection in about a hundred. A terminal that redraws a long line is allowed for by matching the start marker only
as a whole line and the end marker only when digits and a line end follow.

**Not verified.** The app's switch in the running app (the window was not driven; the builder code is a copy of the helper's,
which was run for real, and the unit tests cover the switch, the profiles, the exposure line, the socket placement and the
help). The count of bytes the bridge dropped is kept in the bridge but not shown anywhere, so "nothing dropped" above is
the md5 comparison. Any guest but Alpine's, any console speed above a few MB/s, a client that is slower than the guest by
more than the 1 MiB queue, programs that redraw the whole screen, and macOS guests.
