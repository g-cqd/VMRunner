import NetPolicy

/// Ranges and steps shared by the editor controls and the help text, so the two can't disagree.
enum EditorLimits {
    static let maxDiskGiB = 4096
    static let diskStepGiB = 8
    static let newLinuxDiskGiB = 16...2048
    /// The smallest disk a macOS install was seen to succeed on (a real run); 16 GiB failed. Not probed in between.
    static let newMacDiskGiB = 40...2048
    static func newDiskGiB(for guest: GuestOS) -> ClosedRange<Int> { guest == .macOS ? newMacDiskGiB : newLinuxDiskGiB }
    static let memoryStepMiB = 512
    static let newMemoryStepMiB = 1024
    static let displayWidth = 640...7680
    static let displayHeight = 480...4320
    static let displayWidthStep = 80
    static let displayHeightStep = 50
    static let pixelsPerInch = 72...326
    static let pixelsPerInchStep = 2
    /// Linux guest pixels per window point: the editor offers 1x and 2x.
    static let pixelsPerPoint = 1...2
    static let runtimeMinutes = 0...1440
    static let runtimeStepMinutes = 15
    /// Rules one policy list may hold. Every rule is checked on each new connection, so the list is kept human-sized.
    static let maxRulesPerList = 200
    /// Longest rule, in the canonical text a policy stores it as. The policy enforces it, so it owns the value.
    static let maxRuleLength = NetworkPolicy.maxRuleLength
    /// Characters in a short free-text field: a machine or snapshot name, the first-boot account's full name and user name, a
    /// MAC address, a guest version.
    static let maxTextLength = 255
    /// Longest host path, in bytes: the system's `PATH_MAX`.
    static let maxPathLength = 1024
    /// Shared folders, and extra disks, one machine may have.
    static let maxHostItems = 64
    /// The framework's limit on a virtio disk's identifier, in ASCII characters.
    static let maxDiskSerialLength = 20
    /// Lines the live connection log keeps; older ones fall off.
    static let recentFlowLimit = 200
}
