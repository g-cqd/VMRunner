---
status: pending
blocked-by: ["0009"]
date: 2026-10-21
decision: ADR-0006
---
# 0030 — Validate the filtered network and the runner against real guests

CI cannot start a VM and agents never start one, so everything below is run by the owner on a Mac, once for **one macOS guest
and one Linux guest**, and reported back. Results go into the diary; each defect becomes a fix with a regression test, and the
outcome decides ADR-0006 "What this does not decide".

## How to report

For each row write `pass`, `fail` or `skip`, plus what you saw for a `fail` (the guest's message, the flow log line, the time).
A short note per row is enough. Use a fresh machine per guest, with the default security profile unless a row says otherwise.
Keep the Network popover open while testing: it shows the allowed and blocked counts and the log.

## Checklist

Setup: the host has working Wi-Fi or Ethernet. Use `example.com` and a host you control as targets.

| # | Area | Steps | Expect |
|---|---|---|---|
| 1 | Boot | Set Network → Mode to Filtered, start the machine | Boots to the desktop or a shell; the Network toolbar button appears |
| 2 | DHCP | In the guest read the address, router and DNS server (`ip addr`, `ip route`, `resolvectl status`; macOS: Network settings) | An address in the stack's subnet, a router, a DNS server; the lease renews without a drop (`dhclient -r` or toggle the interface) |
| 3 | DNS | `nslookup example.com` and `curl -I https://example.com` | Both resolve; the log shows a lookup and a connection, both allowed |
| 4 | Deny by domain | Add `example.com` to the deny list, retry `curl` | The connection fails at once with the refuse action; the blocked count rises; the log names the domain |
| 5 | Allow by domain | Switch the policy to allow-list mode with only one domain | That domain works; every other host is blocked |
| 6 | IP, port, URL rules | Add an IP rule, a port rule and a URL rule one at a time, retry each | Each blocks exactly what it names and nothing else |
| 7 | Deny action | Set "When a connection is blocked" to Ignore, retry a blocked connection | The program hangs until it times out; nothing is revealed |
| 8 | Live edit | With the machine running, edit the lists | The change applies without a restart; an open blocked flow is cut |
| 9 | Flow log | Make 20 connections, then more than the log bounds | The newest are shown first; the counts match what you made; the log stays bounded |
| 10 | VPN indicator | Start WireGuard inside the guest | The panel flags a tunnel in the guest. Also report whether an HTTPS-wrapped VPN is missed (expected) |
| 11 | Host VPN | Turn a VPN on and off on the Mac | The host row follows it within seconds |
| 12 | Path change | With "Reset connections when my Mac changes network" on, switch Wi-Fi to another network during a download | The connection resets and the guest reconnects; with it off the flow stays |
| 13 | Throughput and MTU | `iperf3 -c <host you control>` both directions; `ping -M do -s 1472 <host>` (macOS: `ping -D -s 1472`) | Report MiB/s each way; report whether large packets pass. Roughly 800 MiB/s is the loopback figure; anything above 100 MiB/s is fine |
| 14 | Suspend and resume | Suspend, quit the app, start again, resume | The guest resumes with its connections or recovers them; if the app refuses with a message, copy it (`validateSaveRestoreSupport`) |
| 15 | NAT regression | Switch the same machine back to NAT | Boots, gets a lease, browses |
| 16 | Display | Resize the window, use full screen, change resolution, Retina on and off | The guest follows the window; no distortion |
| 17 | Snapshot, duplicate, disposable | Take a snapshot and restore it; duplicate the machine; start a disposable copy and discard it | Each works; the duplicate and the disposable start with their own network state |

## Outcome

Fill in the diary with one row per checklist number. A `fail` becomes a fix; a `skip` stays listed under "Not verified".
Once every row for both guests is `pass` or has a fix with a test, move ADR-0006's open question into its Evidence section
and set this entry to `done`.
