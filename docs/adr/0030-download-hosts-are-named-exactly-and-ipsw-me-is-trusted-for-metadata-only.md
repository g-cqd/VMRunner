---
status: accepted
date: 2026-10-22
---
# 0030 — Download hosts are named exactly and ipsw.me is trusted for metadata only

This ADR amends [ADR-0015](0015-installers-come-from-the-vendors-over-https-with-pinned-hosts.md). Its decision 1 (downloads
come from "a named set of host suffixes") is replaced by the decisions below, as [ADR-0021](0021-alpine-and-ubuntu-lts-are-offered-from-single-pinned-hosts.md)
did for Alpine and Ubuntu. The rest of ADR-0015 and ADR-0023 stands.

## Context

A host suffix admits every subdomain. `debian.org` covers `salsa.debian.org` and `people.debian.org`, which serve files
that Debian users upload; `apple.com` and `cdn-apple.com` cover every host those domains delegate. ipsw.me is a third party
that supplies, for each restore image, both its URL and its SHA-256, so a compromised or spoofed catalog could choose
where the file comes from and the hash that proves it. The hosts the vendors really use were read on 2026-10-22: the
ipsw.me API lists only `updates.cdn-apple.com` URLs, Apple's own restore catalog (`mesu.apple.com`) lists only
`updates.cdn-apple.com` URLs, `mirror.stream.centos.org` serves the CentOS listing, checksums and ISOs directly, and
`deb.debian.org` serves the Debian netboot image and its index directly.

## Decision

1. The allow-list holds exact host names and no suffixes: `updates.cdn-apple.com`, `mirror.stream.centos.org`,
   `deb.debian.org`, `cdimage.debian.org` (the listing and signed checksums of the unregistered Debian netinst candidate),
   `dl-cdn.alpinelinux.org` and `cdimage.ubuntu.com`. A host is added with the provider that needs it.
2. `api.ipsw.me` is accepted only for small documents (the catalog itself), never for a download, a signature or a
   redirect of a download.
3. A restore image taken from the catalog must be on `updates.cdn-apple.com`, be named `*.ipsw` and come with a SHA-256 of
   64 lowercase hexadecimal digits. The catalog is checked when it is decoded, and an entry that fails is dropped, so the
   list the user sees holds only downloadable builds.

## Consequences

A vendor that moves its files to another host stops working until the allow-list is changed, which is the point: the
change is reviewed. The AlmaLinux, Rocky Linux and Fedora hosts remain unregistered, as before. The ipsw.me checksum
still detects corruption and not a substituted file served together with a matching hash, because both come from the
same third party; Apple's installer verifies the image's own signatures.

## What this does not decide

Whether a restore image should also be checked against a digest from a source other than ipsw.me.
