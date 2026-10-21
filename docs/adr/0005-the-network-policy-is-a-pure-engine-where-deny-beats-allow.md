---
status: accepted
date: 2026-10-21
---
# 0005 — The network policy is a pure engine where deny beats allow

## Context

Users want allow-lists and deny-lists for IPs, ports, connections, domains and URLs. Rules written as text are easy to
bypass if the parser and the resolver read a host differently.

## Decision

1. `NetworkPolicy.evaluate` is a pure function of the policy, the host, the port and the addresses it resolved. It never
   throws; unparseable input is a denial.
2. A deny rule beats an allow rule; in allow-list mode anything not allowed is denied.
3. Non-canonical IP spellings (`2130706433`, `0x7f000001`, `127.1`, octal forms) are denied rather than interpreted.
4. Every resolved address must pass, which closes DNS rebinding; IPv4-mapped IPv6 forms are normalised first.
5. Private, loopback and link-local ranges are denied by default.
6. For URLs, credentials in the authority are ignored (the host actually connected to is judged), a backslash is denied,
   the path is decoded and `..`-resolved, and path rules apply only to `http`, because the path of an `https` request is
   not visible.

## Consequences

The engine is testable without a network. It decides; it does not enforce. Enforcement is ADR-0006.

## What this does not decide

Domain rules are advisory when several names share an address.
