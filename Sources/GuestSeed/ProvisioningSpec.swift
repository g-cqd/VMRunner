/// What a user asks a new machine to run (ADR-0012): `apiVersion: vmrunner.dev/v1alpha1`, `kind: Provisioning`,
/// `metadata.name`, and a `spec` with a `cloudInit` section passed through as given and an ordered `provision` list of steps.
package struct ProvisioningSpec: Equatable, Sendable {
    package static let apiVersion = "vmrunner.dev/v1alpha1"
    package static let kind = "Provisioning"

    /// `metadata.name`: a DNS label, which also becomes the guest's host name.
    package let name: String
    package let cloudInit: CloudInitSource
    /// The steps in the order the spec lists them.
    package let steps: [ProvisioningStep]
}

/// The `spec.cloudInit` section, under the field names KubeVirt uses: cloud-init data passed through to the seed as given.
package struct CloudInitSource: Equatable, Sendable {
    /// `userData`, or `userDataBase64` decoded.
    package var userData: SpecText?
    /// `networkData`, or `networkDataBase64` decoded; it becomes the seed's `network-config`.
    package var networkData: SpecText?
}

/// Text from the spec with the line it was given on, so a later check can still point at it.
package struct SpecText: Equatable, Sendable {
    package let text: String
    package let line: Int
}

/// When a step runs (`docs/research/provisioning-2026-10.md`, "Where a script can run").
package enum ProvisioningPhase: String, CaseIterable, Sendable {
    case preInstall = "pre-install"
    case postInstall = "post-install"
    case installError = "install-error"
    case earlyBoot = "early-boot"
    case firstBoot = "first-boot"
    case everyBoot = "every-boot"
    case ready
    case preShutdown = "pre-shutdown"
}

/// Who a step runs as in the guest: root, or the guest's default user.
package enum StepUser: String, Sendable {
    case system
    case user
}

/// A step's script: written in the spec, or a file beside the spec with the SHA-256 the host checks before packing it.
package enum StepScript: Equatable, Sendable {
    case inline(String)
    case file(path: String, sha256: String)
}

/// An `env` entry with its value written in the spec: it travels in the seed with the script.
package struct StepVariable: Equatable, Sendable {
    package let name: String
    package let value: String
}

/// An `env` entry whose value is a secret, delivered by the guest agent when the step runs. It holds the secret's name and
/// nothing else: no type of this library holds a secret's value, so none can be written into a seed.
package struct SecretVariable: Equatable, Sendable {
    package let name: String
    package let secretName: String
}

/// One entry of `spec.provision`, with the line it starts on.
package struct ProvisioningStep: Equatable, Sendable {
    package let line: Int
    package let phase: ProvisioningPhase
    package let user: StepUser
    package let script: StepScript
    /// The `env` entries with a value.
    package let variables: [StepVariable]
    /// The `env` entries with a `secretRef`; never written into the seed.
    package let secrets: [SecretVariable]
}
