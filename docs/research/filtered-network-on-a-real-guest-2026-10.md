---
date: 2026-10-22
question: "Does the filtered network do what the policy says on a real Linux guest, and how fast is it?"
feeds: [roadmap 0030, ADR-0053]
---
# The filtered network on a real Linux guest

**Verified on a real guest (2026-10-22)**, by the rows of roadmap 0030 that a terminal can drive. The guest was Alpine Linux
3.24.2 (aarch64 netboot image, 2 CPUs, 2048 MiB, no disk) booted by `vmr guest start --net filtered` in a headless helper
(ADR-0052, ADR-0053) on an Apple M3, macOS 26.7.1, with a debug-built helper and other builds loading the machine. Commands
ran in the guest through the console (`vmr guest exec`), policies were replaced while it ran (`vmr guest policy`), and what the
stack did was read from the helper's events (`vmr guest flows`). Nothing was driven through a window.

Paths below are shortened: `SOCK` is the console socket `vmr guest start` printed, and `exec` is `swift run vmr guest exec SOCK --`.

## Results by row

| # | Row | Commands and what was seen | Verdict |
|---|---|---|---|
| 1 | Boot | `start --net filtered`: console socket ready 0.06 s, machine running 0.11 to 0.17 s, login prompt 9.7 to 10.5 s after launch (the package install over the stack is most of it: DHCP, DNS and 23 MB over TLS, 2 flows, in the first 10 s). No toolbar button: there is no window | pass (headless) |
| 2 | DHCP | `exec 'ip -4 addr show eth0; ip route; cat /etc/resolv.conf'`: `inet 198.18.0.2/24`, `default via 198.18.0.1 dev eth0 metric 202`, `nameserver 198.18.0.1`. `exec udhcpc -i eth0 -n -q -f`: `lease of 198.18.0.2 obtained from 198.18.0.1, lease time 86400`; the address and route were unchanged, `wget` worked straight after, and the counter went `dhcpAcks=1` to `2` | pass |
| 3 | DNS and connections | `exec nslookup example.com`: `Server: 198.18.0.1`, two A records (the stack answers no AAAA). `exec wget -q -O /dev/null --spider http://example.com` and `... https://example.com`: both exit 0. Flow lines: `DNS answered example.com: Name resolved`, `TCP allowed example.com (172.66.147.243:80)`, `TCP closed example.com (172.66.147.243:443): finished, 1733 bytes to the host, 6520 to the guest, 0.21 s`. (Alpine's base has no `curl`; busybox `wget` was used) | pass |
| 4 | Deny by domain | Policy `{"blockedDomains":["example.com"]}` applied in 70 ms: `nslookup` answered `** server can't find example.com: NXDOMAIN`; `wget` failed at once with `bad address 'example.com'`; `www.iana.org` still worked. Log: `DNS denied example.com: The name matches the blocked domain example.com.`; `dnsBlocked` rose. A connection to the address itself is not stopped by a name rule, as the help says | pass |
| 5 | Allow by domain | Policy `{"mode":"allowListed","allowedDomains":["example.com"]}`: example.com over http and https worked; `www.iana.org` was NXDOMAIN (`DNS denied www.iana.org: Not on the allow-list.`); `wget http://1.1.1.1` failed with `Connection refused` and `TCP denied 1.1.1.1:80: Not on the allow-list.` | pass |
| 6a | IP rule | `{"blockedAddresses":["104.20.23.154","172.66.147.243"]}` (example.com's two addresses): `wget http://example.com` failed with `bad address` (the answer with a blocked address is refused: `DNS denied example.com: 104.20.23.154 is inside the blocked address rule 104.20.23.154.`); `www.iana.org` worked | pass |
| 6b | Port rule | `{"blockedPorts":["443"]}`: `wget https://example.com` failed with `Connection refused`, `TCP denied example.com (104.20.23.154:443): Port 443 is blocked.`; `http://example.com` worked | pass |
| 6c | URL rule | `{"blockedURLPrefixes":["http://example.com/blocked"]}`: `wget -S -O /dev/null http://example.com/blocked` reached the server and printed `HTTP/1.1 404 Not Found`, no denial in the log | **fail: not enforced.** The stack judges a connection and never reads a request; `NetworkPolicy.evaluate(url:)` is called nowhere. The help and the editor's tooltip now say so (fixed there, with a test); enforcing needs a proxy of some kind (ADR-0053) |
| 7 | Deny action | Started with `--deny-action drop`, then policy `{"blockedPorts":["443"]}`: `wget -T 6 https://example.com` returned after 6063 ms (`download timed out`); with the default `reset` the same refusal is immediate. `http://example.com` worked (76 ms) | pass |
| 8 | Live edit | Default, deny `example.com`, default again, with no restart: `example-ok`, then `bad address`, then `example-ok-again`. Open flow: a background `wget` of the 432 MB netboot archive, then policy `{"blockedDomains":["dl-cdn.alpinelinux.org"]}`: `wget: read error: Connection reset by peer`, no `wget` left, and `TCP revoked dualstack.j.sni.global.fastly.net (151.101.66.132:80): The name matches the blocked domain dl-cdn.alpinelinux.org.` | pass |
| 9 | Flow log | 20 `wget --spider` in one `exec`: `tcpFlowsOpened` 20 to 40, `dnsQueries` +40 (A and AAAA each), `flowEventsDropped=0`, and 26 `TCP allowed example.com` lines in the log for the run (20 and 6 earlier). The bounded list is the app's window: not run | pass (helper side) |
| 10 | VPN indicator | Two UDP datagrams shaped like a WireGuard initiation (`01 00 00 00` and 144 random bytes) to `1.1.1.1:51820` with `nc -u`: after the second, `Guest VPN: WireGuard suspected (medium confidence)`. Real WireGuard and an HTTPS-wrapped VPN were not tried | partial |
| 13 | Throughput | To a server on the Mac itself at 10.0.0.42 (reachable because the policy had `blockPrivateRanges` off; see the floor below): download 1,000,000,116 bytes in 2.01 s (about 474 MiB/s); upload 500,170,839 bytes in 1.15 s (about 415 MiB/s), from the flow events. Against the internet the figures are the link's: 100 MiB over plain http from the Alpine mirror in 15 s (about 7.0 MiB/s; the Mac's own `curl` got 6.8 MB/s of the same file) and 20 MiB uploaded to speed.cloudflare.com in 9.21 s (2.28 MB/s; `curl` 2.38 MB/s). busybox `wget` over TLS to proof.ovh.net took 159 s for 125 MB (the guest's TLS, not the stack: `curl` on the Mac got 6.8 MB/s). Debug-built helper | pass (above 100 MiB/s) |
| 13 | MTU | `ping -s 1472 1.1.1.1` (a 1500-byte packet) passed; `-s 1473` and `-s 3000` lost every packet: the guest fragments them and the stack drops IP fragments (`droppedFragments=10`). TCP is unaffected (MSS 1460) | pass, with the limit stated in the help |
| 15 | NAT regression | The same image with the framework's NAT: `inet 192.168.64.x/24`, route via 192.168.64.1, `nslookup example.com` and `wget http://example.com` worked | pass |
| 11, 12, 14, 16, 17 | Host VPN, path change, suspend and resume, display, snapshots | need a window or a change of the Mac's network | skip |

**The floor and the private ranges** (the extra rows of the brief). With the default policy `wget http://10.0.0.42:8089/`
(the Mac's LAN address) gave `Connection refused` and `TCP denied 10.0.0.42:8089: 10.0.0.42 is a private network address,
and private ranges are blocked.` With `{"blockPrivateRanges":false}` the same request returned the page (the Mac's own
LAN address is not in the floor, as the exposure summary says: loopback, link-local and the virtual network are) and the
router at 10.0.0.1 answered. The floor held under that policy: `169.254.169.254` (`a cloud metadata address, and the guest
is never let reach those`), `192.168.64.1` (`your Mac's side of the virtual network`), `198.19.0.7` (`in the range the virtual
network itself uses`) and `198.18.0.1:8080` (`Only DNS is served at the gateway (port 8080 is not)`) were all refused, and
`nslookup localtest.me` (which resolves to 127.0.0.1) was refused with `127.0.0.1 is a loopback address, and the guest is
never let reach those`.

**Under the Seatbelt engine.** The same guest on the filtered network booted inside the generated profile at the standard
level (`sandbox-exec -f seatbelt.sb VMHelper --start`); DHCP, DNS, TCP and ping worked and the flow events were reported.
Live policy changes were not run there (no command pipe), nor the App Sandbox engine.

## Defects found

1. **A reply to a ping reached the guest once per recent ping** (`DUP!` in busybox `ping`): macOS gives an echo reply to every
   ICMP socket connected to the replying address and each flow relayed what it read. Fixed in `DatagramFlow` (a flow passes on
   only the replies with its own identifier), with a regression test; checked on a real guest afterwards (no `DUP!` in
   twelve pings of four sizes).
2. **URL prefix rules are not enforced** (row 6c, above). The help and the tooltip said they were matched. Fixed in the
   wording, with a test; the enforcement is a decision of its own.
3. Found before it was committed: the helper's command reader used `FileHandle.read(upToCount:)`, which on a pipe waits for
   the whole count, so a command line was never seen; it reads with `read(2)` now.

## Not verified

The macOS guest, any guest but Alpine, IPv6 (the stack gives the guest none), UDP applications beyond DNS and a ping, a
Wi-Fi or VPN change on the Mac (rows 11 and 12), suspend and resume (row 14), the app's window and its bounded log, and the
numbers with a release-built helper.
