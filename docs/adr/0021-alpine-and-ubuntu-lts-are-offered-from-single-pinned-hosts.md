---
status: accepted
date: 2026-10-21
---
# 0021 — Alpine and Ubuntu LTS are offered from single pinned hosts

## Context

ADR-0015 limits the offered Linux installers to a short list of vendors and leaves the rest as candidates until the owner
chooses. Debian and CentOS Stream were offered; Alpine Linux and Ubuntu Server were verified candidates. Their real
index and checksum files were fetched on 2026-10-21: Alpine's `dl-cdn.alpinelinux.org` and Ubuntu's `cdimage.ubuntu.com`
serve the ISO, the listing and the checksum file directly, with no redirect to another host.

## Decision

1. Alpine Linux (the aarch64 `virt` ISO, from `/alpine/latest-stable/releases/aarch64/`, one `.sha256` file per ISO) and
   Ubuntu Server (the arm64 live-server ISO of the current LTS, from `/ubuntu/releases/<release>/release/`, one
   `SHA256SUMS` file for the directory) are offered.
2. Each is pinned to the single host that serves it. The allow-list holds `dl-cdn.alpinelinux.org` and
   `cdimage.ubuntu.com`, not `alpinelinux.org` or `ubuntu.com`, so the vendors' other hosts and mirrors stay refused.
3. The newest stable Alpine is the highest release number in the listing; release candidates and other flavors never
   match. Ubuntu is pinned to one LTS release (26.04) and takes its newest point release; the `+largemem` variant and
   other architectures never match. A new LTS is a new catalog entry, not a silent switch, because the installer, its size
   and its support window change.
4. The ISO is checked against the checksum file fetched over HTTPS from the same host, as for the other vendors.

## Consequences

Alpine has no Secure Boot support, so its catalog entry says so and the help tells the user to leave Secure Boot off for
it. The Ubuntu entry goes stale until a new entry is added when the next LTS ships (April of an even year).

## What this does not decide

Verifying the OpenPGP signatures both vendors publish (Alpine's `.asc` per ISO, Ubuntu's `SHA256SUMS.gpg`), which stays with
roadmap 0023, and the remaining candidates (AlmaLinux, Rocky Linux, Fedora, Debian netinst).
