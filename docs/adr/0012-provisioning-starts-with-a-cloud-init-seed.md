---
status: proposed
date: 2026-10-21
---
# 0012 — Provisioning starts with a cloud init seed

## Context

Users want to install from an ISO and run scripts at install steps, compatible with Kubernetes tooling. The framework has
no kernel arguments under UEFI, no `fw_cfg` and no guest agent.

## Decision

1. The main carrier is a cloud-init NoCloud seed: a read-only `cidata` volume attached as a read-only block device (a virtio disk).
2. Installer seed media follow by label: `OEMDRV` for Fedora-family kickstart and openSUSE AutoYaST, `cidata` for Ubuntu
   autoinstall, a repacked ISO for Debian preseed.
3. A small vsock agent runs steps, reports progress and delivers secrets. Secrets never go in the seed.
4. The user-facing spec is a Kubernetes-style envelope with Lima-style steps, compiled to cloud-init, with the
   `cloudInit` section passed through under KubeVirt's field names.
5. Every script file carries a SHA-256 checked on the host.

## Consequences

Nothing was built when this was decided. Each step needs a real guest run before its help may say it works. See `docs/research/provisioning-2026-10.md`.

2026-10-23: items 4 and 5 and the seed's contents are built as a library, `Sources/GuestSeed`, with nothing linking it
yet and nothing run in a guest. The input is a strict subset of YAML read without a dependency; the seed is an ISO 9660
image with Joliet names written by the library, reproducible to the byte, rather than `hdiutil makehybrid`, whose output
differs from run to run and which would be a subprocess of the app. Item 1's attachment, item 2 and item 3 are not built;
roadmap 0016 lists what remains.

2026-10-23, later the same day: items 1 to 3 are built. A Linux machine's spec is compiled at each start into a seed in its
bundle and attached as a read-only USB mass storage device, with an editor section, a help topic marked experimental, a
line in the exposure summary, the strict profiles removing it, and a managed key. The bus was USB as decided, for the
reasons then given (cloud-init finds the volume by its label whatever the bus; the app already boots installers from USB;
a USB device can be detached while the machine runs). The note of the same date below changes the bus. No guest had read
the seed when this was written. Items 4 and 5 are not built (the roadmap now numbers them 2 and 3).

2026-10-23, after the first real-guest runs: the seed is a read-only virtio disk, not USB. The first run, with a Debian 13
generic arm64 cloud image and the app's seed attached as a USB drive, showed no cloud-init activity: the host name stayed
`localhost` and no marker line appeared in 9 min 52 s. The second run showed that the kernel sees the USB drive (it listed
as `sda`, read-only, label `cidata`, `iso9660`), and that cloud-init found a seed on a read-only virtio disk (data source
`config-disk` on `vdb`, host name set, `bootcmd` and `runcmd` markers seen). That virtio disk held an ISO built with
`hdiutil`, not the app's. USB alone was not shown to work or fail on that image, because cloud-init chose the virtio disk
first. The likely cause is that the USB drive appears after the services that look for a data source have started
(inferred, not verified). Not yet seen: the Joliet names read by Linux, the Merge-Type merge, scripts running from
`/var/lib/cloud/vmrunner`, `base64`, and suspend with the drive attached. The ADR stays proposed.

2026-10-23, third real-guest run: with the app's own seed attached as a read-only virtio disk, on a Debian 13 generic arm64 cloud image, cloud-init found it (data source `config-disk` on `/dev/vdb`, label `cidata`). Linux read its Joliet names (`user-data` and `meta-data`, in lower case). The two-part `Merge-Type` merge worked: `user-data-parts=2`, the user part's `runcmd` ran, and one reboot took effect. The scripts ran from `/var/lib/cloud/vmrunner` as uid 0 on a mount without `noexec`, `base64` exists on the image, and the every-boot step ran at both boots. The status stays `proposed`: the owner decides acceptance. The evidence is one image of one distribution (Debian only). Not seen: other distributions' images; suspend with the seed attached (the toolbar's button state was not observed); the exposure line in the window; and the guest's own poweroff line, which is inferred from Start being enabled again after the run.

## What this does not decide

Whether to repack ISOs or boot the kernel directly for installers that insist on a kernel argument; both are unverified.
