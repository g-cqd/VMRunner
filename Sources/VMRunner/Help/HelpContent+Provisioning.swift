extension HelpCatalog {
    /// Provisioning a Linux guest from a spec through a cloud-init seed (ADR-0012). Experimental until a real guest has run it.
    static let provisioning: [HelpTopic: HelpEntry] = [
        .provisioning: HelpEntry(
            area: .machines,
            title: "Provisioning (experimental)",
            summary: "Runs your scripts in a Linux guest at boot, from a spec file, through a cloud-init seed. Experimental.",
            paragraphs: [
                "Experimental: this has not yet been tried with a real guest, so it may not work with every Linux image. It is "
                    + "meant for cloud images that include cloud-init.",
                "A provisioning spec is a small text file you write. It names the machine and lists scripts to run at "
                    + "**early-boot** (every boot, before the network), **first-boot** (once per machine) or **every-boot**, and "
                    + "it can carry cloud-init data of your own. Choose it under **Provisioning** in the machine's settings.",
                "At each start VMRunner reads the spec and every script file it names again, checks each file against the "
                    + "SHA-256 the spec gives, and builds a small read-only drive labelled `cidata` that cloud-init in the guest "
                    + "reads. If anything is wrong, the machine does not start, and the message names the line of the spec.",
                "Everything in the spec and its scripts can be read inside the guest, and the scripts run as root: never put "
                    + "a password or a key in them. \"What this machine can reach\" lists the spec while it is in use.",
                "The Isolated and Hardened profiles remove the spec. It is not used while the installer is attached: detach "
                    + "the installer once the system is installed. Your organisation can turn it off with `AllowProvisioning`.",
            ],
            advanced: [
                "The spec: `apiVersion: vmrunner.dev/v1alpha1`, `kind: Provisioning`, `metadata.name` (the guest's host "
                    + "name), and `spec` with `cloudInit` (`userData` and `networkData`, or their `Base64` forms, passed "
                    + "through) and `provision`, a list of steps with `at`, `user`, `script` or `file` with `sha256`, and `env`. "
                    + "It is a strict subset of YAML: anything else is refused with its line.",
                "Not supported yet, and refused: the installer steps (`pre-install`, `post-install`, `install-error`), "
                    + "`ready`, `pre-shutdown`, `user: user` and `secretRef`. A secret never goes into the seed.",
                "Limits: 64 KiB of spec, 32 steps, 64 KiB per script file. A `file` path is relative to the spec's folder "
                    + "and may not leave it or go through a symbolic link.",
                "The seed is an ISO 9660 image attached as a read-only USB drive. It is rebuilt at every start, so an edited "
                    + "spec takes effect at the next start and deleted when the machine stops. Its instance identifier is the "
                    + "machine's, so first-boot steps run once per machine (editing one that has already run changes nothing in "
                    + "that machine); a disposable machine runs them at every start. A suspended machine whose seed changed "
                    + "starts afresh instead of resuming.",
                "In the guest, scripts are unpacked into `/var/lib/cloud/vmrunner` and need `base64`.",
            ],
            related: [.exposureSummary, .securityProfiles, .installerISO, .disposable, .managedSettings]
        )
    ]
}
