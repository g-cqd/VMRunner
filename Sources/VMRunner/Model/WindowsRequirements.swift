/// What the app tells a person about a Windows machine before they make one: the requirements panel of the New Machine sheet
/// and the notes beside its media slots. The text lives here, in one place, so a test can read all of it.
///
/// The app provides the machine, the media slots and these statements. It does not download Windows, does not change the
/// installer and does not touch what Windows Setup checks.
enum WindowsRequirements {
    /// The requirements panel, one statement per line.
    static let lines: [String] = [
        "Uses private interfaces of the virtualization framework (performance-monitoring and fine-grained trap emulation). "
            + "These are off in the Isolated and Hardened profiles and by the AllowPrivateInterfaces managed setting.",
        "Windows 11 Setup checks for a TPM 2.0 device. This machine has none: the app does not provide one and does not work "
            + "around the check. Meeting Windows Setup's requirements and the licence terms is up to you.",
        "No suspend: a Windows machine can only be shut down or stopped.",
        "Each Windows installation needs its own licence. Insider Preview builds follow the Windows Insider Program's terms and "
            + "expire; retail builds do not.",
        "The framebuffer-assisted boot path currently supports macOS build 26A434 only. Other builds are refused until verified.",
        storageDriver,
        networkDriver,
        "Secure Boot is off.",
    ]

    static let displayNote =
        "The experimental RAM framebuffer uses one fixed mode; the window scales the picture. "
        + "No graphics acceleration or dynamic resolution."

    static let storageDriver =
        "Use a Virtio main disk and an ARM64 virtio-win driver disc. In Setup, choose Load driver, "
        + "then viostor\\w11\\ARM64; keep compatibility filtering on."

    static let networkDriver = "Windows has no built-in driver for this machine's network device: networking needs a driver disc."

    static let installerNote = "Choose a Windows 11 ARM64 installer ISO that you already have. The app does not download Windows."

    static let expectedSHA256Note =
        "When this is filled in, the app computes the ISO's SHA-256 before it makes the machine and stops if it differs. "
        + "Leave it empty to skip the check."

    static let driverDiscNote =
        "Attached as a read-only USB drive. Supply ARM64 viostor for storage and NetKVM for networking; "
        + "x64 drivers are not compatible. You can change it later."

    static let sharingNote =
        "A Windows guest sees shared folders and host information only if you install a virtio file-system driver in it."

    /// What the settings say under the security profile of a Windows machine whose profile closes private interfaces: it
    /// needs one, so it would not start. Nil for any other machine.
    static func profileNote(for config: VMConfig) -> String? {
        guard config.guest == .windows, let profile = config.detectedProfile,
            PrivateCapabilityPolicy.closingProfiles.contains(profile)
        else { return nil }
        return "The \(profile.label) profile turns off private interfaces and this machine needs one: it will not start. "
            + "Pick another profile."
    }
}
