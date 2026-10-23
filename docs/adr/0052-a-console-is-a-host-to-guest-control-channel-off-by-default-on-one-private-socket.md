---
status: accepted
date: 2026-10-22
---
# 0052 — A console is a host-to-guest control channel: off by default, on one private socket

## Context

Acting on a guest without a screen or a network needs a channel the host controls. The first one is a serial console: the
guest's first virtio console port (`hvc0` on Linux) bridged to the host. It is a raw byte pipe, and once a getty listens on
the guest's side it is a login prompt, so whoever can write to it holds a shell in the guest (root, on a live image). The
automation study (`docs/research/automation-2026-10.md`) lists it as one door among several and says to protect it like a
root shell. It is also the first block of the automation server (roadmap 0005), and the way the owner's authorised
real-guest runs act on a guest (`vmr guest`, `CONTRIBUTING.md`).

The real runs showed the practical limits that shape the rules below: a local socket path holds 103 bytes and a machine
bundle in the usual place is longer than that; a process that exits leaves its socket file behind; a guest can print faster
than a client reads, and can print while no client is attached.

## Decision

1. **Off by default, per machine.** A Linux machine has a switch, `serialConsole`, false until the user turns it on. macOS
   guests have none: the switch is disabled for them and the builder ignores a stored value. The headless helper has a
   console only when its descriptor names a socket.
2. **Isolated and Hardened force it off.** The Standard and Contained profiles leave the user's choice alone, as they do for
   Rosetta. Turning it back on after a closed profile reads as Custom.
3. **Listed in the exposure summary** as "A serial console is reachable from this Mac as a local socket at <path>", at the
   medium level: any process of this user can type into the guest.
4. **One private local socket, no network.** The socket is created with mode 0600 in a directory that must already be owned
   by the user and closed to everyone else (the machine's bundle folder, 0700; when `<bundle>/Console.sock` is longer than
   103 bytes, a short name in a private folder of the user's temporary items). The bridge refuses a longer path, a path that
   holds something other than a socket, a socket another process serves or another user owns, and a directory open to
   others; a stale socket of the user is removed. A client must run as the user (checked with the peer's credentials).
   Nothing listens on an address, and no port of vsock or the network carries it.
5. **One client at a time.** A second connection is told so in one line and closed. The first keeps working.
6. **The guest is never held up.** Output while no client is attached goes into a 64 KiB replay buffer that drops its oldest
   bytes and is shown to the next client; output for a client that reads more slowly than the guest prints goes into a 1 MiB
   queue that also drops its oldest bytes. Input toward the guest is bounded too, and when the guest stops reading it the
   client is simply not read from. Every drop is counted.
7. **The library is plain.** The bridge and the exec client are `GuestConsole`, a library target that imports Foundation and
   the system's C library only (a test checks it). The app links it, the helper links it, and so does the tooling; it is the
   only library target of this repository the app links, so the app's rule of linking system frameworks and one package
   (ADR-0001) still holds.
8. **The exec protocol is a convenience, not a boundary.** `echo MARK_S_<nonce>; <command>; echo MARK_E_<nonce>_$?` frames a
   command's output and status on the terminal. It makes no claim against a guest that wants to confuse the client.
9. **Real-guest runs use the signed image and the caps.** `vmr guest fetch alpine-netboot` takes the newest release with a
   signature and checks it against the vendor's checksum and, with `gpg`, against the release key pinned by fingerprint;
   `vmr guest start` boots it with at most 2 CPUs and 2 GiB, a hard run-time limit and a scratch directory that is never the
   user's Library.

## Consequences

A machine started from the app with the switch on has a socket for as long as the machine lives: the bridge starts with the
machine, is kept by the object that wraps it, and ends when that object is released or the guest side of the port closes.
A helper that is killed leaves its socket file; `vmr guest stop` and the next start remove it, and a client sees the
console close at once.

An agent and a person cannot hold the console together; the second waits or is refused. A client that reads far more slowly
than the guest prints loses output, and the exec client then fails by timeout or by a missing marker rather than returning
a wrong answer.

The App Sandbox helper could not bind the socket with the entitlements tried; the Seatbelt helper can, with a grant for
that one path. A guest booted from a kernel and an initial ramdisk reached its login prompt inside the Seatbelt helper
(`docs/research/sandboxing-2026-10.md`).

## What this does not decide

Opening the console in the user's terminal application (an app-wide choice with a per-machine override), which the
owner suggested and which needs the client in the app's bundle first. The capability tokens and per-machine agent policy of
the automation server (roadmap 0005). A guest agent over vsock, which would not need a getty. Console support for macOS
guests. Flow control from the host to the guest beyond the bounded queue.

(Update 2026-10-22: an authorised real-guest run found that the Alpine ISO of the app's own catalog boots with
`console=tty0 console=ttyAMA0` after one second at its GRUB menu, so with `serialConsole` on the socket stays silent:
the app boots an ISO through EFI and leaves its kernel command line alone. The guest must boot with `console=hvc0`. The
run did it with a small FAT boot image holding the ISO's files and a `grub.cfg` with `console=tty0 console=hvc0`,
attached as the installer; a user can instead add `console=hvc0` at the GRUB menu. No image in the catalog is known to
start a login on `hvc0` by itself; the help topic *Serial console* says so. The decision is unchanged.)

(Update 2026-10-23: `ConsoleSocket` is `package` now, for the control service (ADR-0056); its behaviour is unchanged.)

(Update 2026-10-23, later: the console client in the tooling, `vmr guest console`, now filters what the guest prints
before it reaches the person's terminal. Text, colours, cursor movement and erasing pass; window titles, the clipboard,
hyperlinks, queries that make the terminal answer, mode changes and resets are removed, and `--raw` keeps the old
pass-through after a warning. The client also puts the terminal back when a signal ends it. The filter is on the client's
side only: the bridge still carries the guest's raw bytes to every client, and decision 8 is unchanged, since the exec
client reads those bytes unfiltered and `vmr guest exec` prints a command's output as the guest sent it. The status is
unchanged.)
