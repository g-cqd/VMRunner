---
status: proposed
date: 2026-10-23
---
# 0056 — Scripts and agents control machines through a local service: off by default, one private socket, capability tokens

## Context

Roadmap 0005 wants scripts and AI agents to drive machines: list them, read their state, start and stop them, and later take
screenshots, type, and run commands. The automation study (`docs/research/automation-2026-10.md`) proposes one control
service inside the app, which owns the machines and the virtualization entitlement, reached over a local socket, with
per-client capability tokens and a per-machine access policy that the security profiles cover. The console (ADR-0052)
settled how this repository makes a private local socket: a private directory, mode 0600, a path-length check, the peer's
credentials, bounded buffers. A control service is a wider door than one console: whoever reaches it can start every machine
it is allowed to, so it stays closed unless the user opens it, and each client holds only what it needs.

## Decision

1. **Off by default, one app-wide switch.** Settings has a switch for the service (the app setting `runsControlService`),
   off until the user turns it on. The managed preference `AllowControlService` (ADR-0013) forced to anything but true keeps
   the service off, turns agent access off on every machine, and locks both controls.
2. **Per machine, off by default.** A machine has `agentAccess`, false until the user turns it on. Every method that names a
   machine refuses one whose access is off, and the list leaves it out. The Isolated and Hardened profiles turn it off;
   Standard and Contained leave the user's choice, as for the serial console. While it is on, the exposure summary says so
   (low): an agent can start and stop the machine, it cannot reach into the guest.
3. **One private local socket, no network.** `control.sock` in `Control`, a folder of the app's data folder created 0700.
   The socket is created 0600 through the console's own code (ADR-0052): a path longer than a local socket holds, a
   directory open to others, something that is not a socket and a socket another process serves are refused, and a stale
   socket of this user is removed. A path that does not fit makes the service refuse to start and say why. Every
   connection's peer must run as the app's user (`getpeereid`), checked before anything is read.
4. **Capability tokens.** A token is 256 bits from the system's cryptographically secure generator, written `vmrc_` and 64
   hex digits, shown once when it is made and stored only as its SHA-256 digest in `Control/tokens.json` (0600) with an id,
   a name, its capabilities (`list`, `state`, `start`, `stop` to begin) and optionally the machines it may act on. A
   presented token is hashed and compared with every stored digest in constant time. A revoked token fails from the next
   request. At most 32 tokens.
5. **JSON-RPC 2.0, strictly.** One request per line. Methods are namespaced: `machines.list`, `machines.state`,
   `machines.start`, `machines.stop`. `params` is an object holding `token` and the method's own members (`machine`, a
   machine's id; `force` for a stop), strings and booleans only; any other member is invalid params. A batch is refused with
   the standard Invalid Request error, and a notification is neither run nor answered. Errors: the standard codes for parse,
   request, method and params errors; -32001 not permitted (no, unknown or revoked token, a missing capability, a machine
   outside the token's), -32002 no such machine, -32003 agent access off, -32004 refused (with the reason), -32005 timed out.
6. **Bounded everywhere.** A request is at most 64 KiB, at most 4 connections are served at once (one more is closed at
   once), a connection serves at most 64 requests and is closed after 10 s without a whole request, a client that stalls a write
   for more than 2 s is dropped; a whole answer is bounded to 10 s, and a request not answered within 120 s is answered "timed out" while what it started goes
   on. No buffer grows with what a client sends.
7. **Every refusal is logged**: the method and the reason in the clear, the token's and the machine's ids redacted, never the
   token, which a refusal does not carry.
8. **Start and stop wait for their result.** The library's start, suspend and stop have variants that return what happened;
   the menus use the same ones. A start for an agent never asks the user: host paths the user has not approved refuse it.
   `machines.stop` asks the guest to shut down and answers at once; with `force` it cuts the power and answers once stopped.
9. **A library target and a thin service in the app.** `ControlProtocol` holds the messages, the tokens and their store, the
   checks, the connection, the listener and a minimal client, all tested without the app; it imports Foundation,
   Synchronization and CryptoKit and links `GuestConsole` for the socket calls, which become `package` there, so the
   private-socket rules have one implementation. Its API is `public`, like the console's. The app holds the service: where
   the socket goes, the switch, the adapter to its machines, the log. The app now links a fourth library target of this
   package; like ADR-0047, this amends ADR-0001 without adding an outside dependency.

## Consequences

An agent needs three things at once: the service on, a token with the capability, and the machine's switch on; each is off
by default, and the closed profiles and an organisation can force the last two off. The kernel's peer check keeps other
users out even if the folder's mode were wrong. Because the token is checked on every request, a revocation takes effect on
open connections too. A client that is slow, silent or too large costs the service at most a few threads and 64 KiB each,
for a bounded time. Requests that start a machine can outlive their answer: the timeout says so rather than stopping the
machine halfway.

The service runs in the app's process: it is up only while the app runs, and a start it makes is the app's own start, with
the same checks and the same saved state.

## What this does not decide

The command-line client and the MCP server over stdio (the next steps of roadmap 0005), screenshots, input and command
execution and their capabilities, confirmations in the app for dangerous calls, token expiry, choosing a token's machines in
Settings (the store supports it), a log of calls the user can read in the app, and a neutral name for the console's socket
helper now that two libraries use it (ADR-0042).

(Update 2026-10-23: built as decided, with unit and end-to-end tests over local sockets; the service has not yet run in the
app with a real client or a real machine. The status stays proposed until the owner's run, roadmap 0005.)

(Update 2026-10-23, later: the command-line client, `vmr control` in the tooling, and an MCP server over stdio,
`vmr control mcp`, are built on the library's client. The MCP server is a library target of its own, `AgentBridge`, which
links this library and the console's and which the app does not link: an agent reaches machines only through the service
and its checks. The client now keeps its read buffer across answers, bounds an answer's size and nesting, and checks the
socket's user before it sends a token. The library's API stays `public`; moving it to `package` is still open. Neither
has run against the app yet; the status stays proposed.)
