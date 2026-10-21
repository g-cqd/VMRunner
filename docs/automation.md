# Automation: a control service, an MCP server, a CLI, and a terminal into the guest

**Status: investigated and partly prototyped, not implemented.** The goal is to let a person, a script, or an AI agent
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
permissions and the blank-capture quirk need re-testing on macOS 27. Nothing here is implemented yet.
