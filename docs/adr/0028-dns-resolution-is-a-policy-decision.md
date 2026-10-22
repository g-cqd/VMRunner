---
status: accepted
date: 2026-10-22
---
# 0028 — DNS resolution is a policy decision

## Context

ADR-0006 gave the guest a DNS proxy in front of the host's resolver and judged connections afterwards. The proxy was an
unrestricted resolver: it forwarded every record type for every name that no block rule named, and echoed whatever the
resolver returned. The host's resolver reaches more than the guest could: split-DNS and VPN zones, `.local` through
multicast, search domains. A guest that picks the names (and, through a name server it controls, the answers) could use
the proxy to probe the host's network, to read internal names and data, and to teach the policy's name table addresses
for names it does not own.

## Decision

1. **Resolving is checked before it happens.** A name is refused, with the configured block response and a denied flow
   event, when a block rule names it; when it ends in `.local` or `.arpa`; and, in allow-list mode, when no allowed domain
   or allowed connection with a name target names it. The check runs again when the answer arrives, because the policy may
   have changed meanwhile.
2. **Reverse lookups are judged as the address they name.** `d.c.b.a.in-addr.arpa` is looked up only when pinging
   `a.b.c.d` would be allowed. Any other `.arpa` name, including `ip6.arpa`, is refused.
3. **Only A, AAAA, CNAME and PTR are answered.** Every other type is NOTIMP and never forwarded. AAAA is answered empty, as
   before, because the guest has no IPv6.
4. **The answer is rebuilt, not echoed.** The CNAME chain from the queried name is followed (at most eight links, every
   target held to the block rules); only records owned by a name on that chain and of the type asked are kept; CNAME and PTR
   data must be one well-formed name and is re-encoded; at most 32 addresses are kept; records that came with an error code
   are dropped.
5. **Addresses the policy refuses on every port are removed** (built-in reserved ranges and blocked addresses). A question
   left with no address is refused and reported as denied. Decisions that depend on the port or on the allow-list stay with
   the connection.
6. **The name table learns only from the validated chain**: each kept address is recorded with the names of that chain.
7. **The resolver is asked for absolute names**, so the Mac's search domains are never appended to what the guest asked.

## Consequences

An allow-list guest can no longer resolve names it has no rule for, so a list of addresses alone gives it addresses to
connect to but no DNS: add the names too. TXT, MX, SRV and HTTPS lookups stop working through the proxy; a guest that needs
them has to be given a rule and a resolver path of its own, which this does not offer. A refusal differs from a name that
does not exist, so in block-list mode a guest can still tell that a name resolves to something the policy removed.

## What this does not decide

Domain rules stay advisory. The name table expires entries after the record's TTL (30 seconds to an hour) and holds a few
thousand addresses, so a guest that waits, or connects to an address it learned elsewhere, is judged by the address alone.
Deriving address blocks from domain rules would close that and is not done here. DNS over HTTPS, TLS and QUIC are still not
intercepted. A pool of resolver workers (today each lookup takes a thread, at most 32 at a time) is also left alone.

(Update 2026-10-22, roadmap 0034 item 4: a block rule for a name on some ports now keeps holding for the addresses the proxy
gave for that name after the table forgets them, and lookups run on at most 32 resolver threads that take queued lookups in
turn. A guest that connects to an address it learned elsewhere is still judged by the address alone.)
