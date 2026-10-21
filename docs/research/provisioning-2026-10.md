---
date: 2026-10-21
question: "How can an ISO install run unattended and run scripts at install steps, compatibly with Kubernetes tooling?"
feeds: [roadmap 0016, ADR-0012]
---
# Installing from an ISO and running scripts during setup

Status: design and investigation. Nothing here is implemented yet. Facts about Virtualization.framework come from the
macOS 27 SDK headers; facts about installers come from the vendors' documentation (linked). Items marked *unverified*
were not tested.

## What Virtualization.framework allows

- **No kernel arguments under EFI.** `VZEFIBootLoader` has only a variable store. `VZLinuxBootLoader` takes a kernel,
  an initrd and a command line, but only on a generic platform, and boots the kernel directly instead of through UEFI.
- **No `fw_cfg`, no SMBIOS strings, no Ignition hook.** So datasources that need them are out.
- **No guest agent from Apple.** The only agent device is the SPICE agent (clipboard). A script channel has to be our
  own: vsock, serial console, a shared directory, or SSH.
- **macOS guests** can be provisioned at first boot with `VZMacGuestProvisioningOptions` (macOS 27 guests): full name,
  user name, password, auto-login, remote login. Nothing else.

## Carriers, in order of how much we trust them

1. **A cloud-init NoCloud seed.** A read-only volume labelled `cidata` (ISO 9660 or FAT) with `user-data`, `meta-data`,
   and optionally `network-config` and `vendor-data` in its root. It needs no kernel argument and no network. Ubuntu,
   Debian, Fedora/CentOS cloud images and Talos' nocloud image all read it. This is the main carrier.
   ([NoCloud](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html))
2. **Installer seed media with an auto-detected label.**
   - Fedora, CentOS Stream, RHEL: a volume labelled `OEMDRV` holding `ks.cfg` is picked up by the installer without a
     kernel argument. (One report says detection failed on CentOS 8; test on arm64 before relying on it. *unverified*)
   - openSUSE/SLE: `autoinst.xml` at the root of a device labelled `OEMDRV`.
   - Ubuntu live server: a `cidata` volume holding `autoinstall:` in `user-data`, but the installer also wants the
     `autoinstall` argument or it asks for confirmation. We would have to answer that prompt over the serial console
     or edit `grub.cfg` in a repacked ISO. ([autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html))
   - Debian: `preseed.cfg` in the initrd root is loaded automatically; a file on other media needs
     `preseed/file=...` on the command line. A repacked ISO or an initrd with the file appended works.
     ([preseed](https://www.debian.org/releases/stable/arm64/apbs02.en.html))
3. **A repacked ISO (xorriso) or direct kernel boot** for installers that insist on a kernel argument. Repacking
   edits `grub.cfg`; whether that keeps Secure Boot happy is *unverified*. Direct boot extracts kernel and initrd from the
   ISO, appends the seed to the initrd and sets the command line, then switches to UEFI for the installed system.
   Whether each distro's arm64 kernel is accepted that way is *unverified*.
4. **Ignition** (Fedora CoreOS, Flatcar): its `applehv` platform fetches the config with an HTTP GET over vsock port
   1024, so the host can serve it with a `VZVirtioSocketListener`. Flatcar support is *unverified*.
   ([supported platforms](https://coreos.github.io/ignition/supported-platforms/))
5. **Talos**: the nocloud image reads the machine config from a `cidata` volume. The metal ISO needs a kernel argument
   (`talos.config=...`) and so needs one of the workarounds above.

Distros that cannot take any of these without a kernel argument are installed interactively, or from a cloud image,
which is usually the better route anyway: a prebuilt arm64 cloud image plus a seed is a boot in seconds, with no
installer at all.

## Where a script can run

| Step | Meaning | cloud-init | Installer |
|---|---|---|---|
| `pre-install` | before the installer touches the disk | – | preseed `early_command`, kickstart `%pre`, autoinstall `early-commands`, AutoYaST `pre-scripts` |
| `post-install` | in the new system, before the first reboot | – | preseed `late_command`, kickstart `%post`, autoinstall `late-commands`, AutoYaST chroot scripts |
| `install-error` | the install failed | – | kickstart `%onerror`, autoinstall `error-commands` |
| `early-boot` | every boot, before networking is up | `bootcmd` | – |
| `first-boot` | once per instance | `runcmd`, `write_files` | – |
| `every-boot` | every boot | a per-boot script or systemd unit | – |
| `ready` | the guest reports it is usable | vsock agent | – |
| `pre-shutdown` | best effort | vsock agent | – |

`runcmd` runs once per instance; `bootcmd` runs every boot, early.
([boot stages](https://docs.cloud-init.io/en/latest/explanation/boot.html))
`pre-shutdown` cannot be guaranteed: a force stop never reaches the guest.

## The spec: a Kubernetes-shaped envelope, Lima-shaped steps

No standard exists for "run this script at this step". The least surprising shape for people who already use these
tools is a Kubernetes-style document whose steps read like Lima's `provision:` list, compiled to cloud-init so that it
is portable:

```yaml
apiVersion: vmrunner.dev/v1alpha1
kind: Provisioning
metadata:
  name: k3s-node
spec:
  cloudInit:                      # passed through; KubeVirt's field names
    userData: |                   #   userData, userDataBase64, networkData, secretRef
      #cloud-config
      package_update: true
  provision:
    - at: first-boot              # pre-install | post-install | early-boot | first-boot | every-boot | ready
      user: system                # system (root) or user
      file: scripts/install-k3s.sh
      sha256: 3f1c…               # required for file:, checked on the host before it is packed
      env:
        K3S_TOKEN: { secretRef: k3s-token }   # delivered over vsock at run time, not written to the seed
    - at: ready
      script: |
        kubectl wait --for=condition=Ready node --all
```

Reasons for each choice:

- **Envelope** (`apiVersion`, `kind`, `metadata`, `spec`): familiar to anyone who writes manifests, easy to validate
  and to version.
- **`cloudInit` pass-through with KubeVirt's names**: a cloud-config from KubeVirt, Cluster API's bootstrap `value` key,
  Multipass or Lima can be dropped in unchanged.
- **Steps shaped like Lima's `provision:`** (`system`/`user`, inline `script` or `file`): the most widely copied form.

Kubernetes tooling that fits: k3s and kubeadm bootstrap from `runcmd`; Talos from a nocloud machine config; Cluster API
bootstrap data as `userData`; Ignition for CoreOS-family nodes. VMRunner would be the local stand-in for the platform
that hands a machine its bootstrap data. It would not implement Cluster API providers.

## Delivery and integrity

- The host builds a **read-only seed image** per start from the spec. It lives in the machine bundle's cache and is
  detached after first boot where the distro allows.
- Every `file:` script carries a **SHA-256 in the spec**. The host refuses to build the seed when a file does not match,
  and a tiny guest agent (below) re-checks before running.
- **Secrets never go in the seed**: cloud-init keeps instance data readable inside the guest. They are delivered over
  vsock when a step asks for them.
- **Scripts run as root in the guest, and the guest is untrusted by the host.** The host exposes nothing writable to it:
  shared directories for scripts are read-only, and an agent only ever receives data, never host paths.
- Provisioning files are plain text in the bundle; the spec shows up in the machine's "what can the guest reach"
  summary (a seed is a channel: it tells the guest things).

## Host-to-guest channels

1. **A small vsock agent** installed by cloud-init: runs steps, reports progress, `ready` and `pre-shutdown`, fetches
   secrets. Needs no guest network and no host listener beyond Virtualization.framework's vsock. This is the approach
   Lima and Apple's containerization use. ([Lima internals](https://lima-vm.io/docs/dev/internals/))
2. **Serial console** for progress markers and as the fallback for answering an installer prompt. Fragile; not a control
   channel.
3. **SSH over the NAT**, discovering the address from the DHCP lease file by MAC address. This breaks for clients that
   do not use a MAC-based identifier. With the user-mode network the guest address is fixed, which removes the problem.
4. **A read-only virtiofs scripts directory plus a systemd path unit**: cheap, no agent, no integrity check beyond
   what the guest does.

## macOS guests

- First boot: `VZMacGuestProvisioningOptions` creates the user and enables remote login (macOS 27 guests only).
- After that, run scripts over SSH, or install a launchd agent over a shared directory. Tart's `tart exec` works the
  same way with a guest agent installed as launchd services.
- There is no cloud-init for macOS, and no hook during `VZMacOSInstaller` beyond its progress object.

## What this cannot do

- Pass kernel arguments under UEFI without repacking an ISO or booting the kernel directly.
- Use `fw_cfg`, SMBIOS datasources, or `ds=nocloud;s=http://…` (all need a kernel argument or firmware support).
- Guarantee a `pre-shutdown` hook.
- Prove to the guest that a script is authentic without a pre-shared key; the integrity check protects the host's copy,
  not the guest from the host.
- Hide a secret from root in the guest.
- Provision macOS beyond the five first-boot options.

## Plan

1. **Seed builder and spec parser.** Parse and validate the spec (strict, with line-numbered errors), build a `cidata`
   image, attach it as a read-only USB mass storage device, expose it in the editor with help. Test with a cloud image
   of a trusted distro. Everything testable without a VM: parsing, hashing, image contents.
2. **Installer seed media.** `OEMDRV` for Fedora-family and openSUSE; `cidata` plus the `autoinstall` prompt answer for
   Ubuntu; preseed via a repacked ISO for Debian. Each distro is its own small, separately tested step.
3. **The vsock agent**, step reporting in the machine view, secrets over vsock, Ignition on vsock 1024.
4. **Kubernetes recipes** as documented examples (k3s, Talos nocloud), not as code.

Each step needs a real guest run before its help text can claim it works. Until then the in-app help says "experimental".
