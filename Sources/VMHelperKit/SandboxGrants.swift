/// How a workload is isolated: the ADR's `none`, `appSandbox` and `seatbelt`. Exclusive: one process gets one sandbox.
public enum SandboxEngine: String, CaseIterable, Codable, Sendable {
    /// A helper bundle signed with `app-sandbox`, `virtualization` and the file access the descriptor needs.
    case appSandbox = "app-sandbox"
    /// The plain helper under `sandbox-exec -f profile.sb`, with a profile generated from the descriptor.
    case seatbelt
}

/// What the engine is asked to allow, beyond the files the descriptor names.
public enum SandboxLevel: String, CaseIterable, Codable, Sendable {
    /// The helper may open host sockets and resolve names, as it must to host a user-mode network stack itself.
    case standard
    /// The helper opens no socket of its own; a guest network would arrive as a descriptor from the app.
    case strict
}

/// Everything either engine is asked to allow for one run, derived once so both engines grant the same thing.
public struct SandboxGrants: Equatable, Sendable {
    public var read: [String]
    public var readWrite: [String]
    /// Outbound sockets and name resolution: only at the standard level, and only for a machine whose network the helper hosts.
    public var hostSockets: Bool

    /// `descriptorPath` is where the helper reads the descriptor itself from, or `nil` when it arrives on standard input.
    /// The descriptor must already be canonical (`HelperDescriptor.canonicalized`).
    public init(descriptor: HelperDescriptor, descriptorPath: String?, level: SandboxLevel) throws {
        var read = descriptor.readPaths
        if let descriptorPath {
            try SandboxPath.validate(descriptorPath)
            read.append(descriptorPath)
        }
        // A path granted for writing is readable already; listing it twice would only widen the profile's text.
        let readWrite = descriptor.readWritePaths
        self.read = Array(Set(read).subtracting(readWrite)).sorted()
        self.readWrite = readWrite
        hostSockets = level == .standard && descriptor.network == .fileHandle
    }
}
