// The provisioning library has no caller outside its tests until a later change attaches the seed to a machine, so a
// declaration only the tests reach is expected here; every other dead-code rule still applies.
// @dw:disable referenced-only-by-tests

/// The bounds the host holds a provisioning spec to before it reads, checks or packs anything. A spec comes from the user's
/// files and a seed is read by an untrusted guest, so every size is capped, and an input past a cap is refused, never cut.
package struct ProvisioningLimits: Equatable, Sendable {
    /// The largest spec, in bytes of UTF-8.
    package var maxSpecBytes: Int
    /// The most steps a spec may list.
    package var maxSteps: Int
    /// The largest script file a step may name, in bytes. A script travels base64-encoded inside one command argument of
    /// the guest's cloud-init, and Linux caps one argument at 128 KiB: 64 KiB is about 87 KiB once encoded.
    package var maxFileBytes: Int
    /// The deepest nesting of maps and lists the reader follows.
    package var maxDepth: Int

    /// The limits a spec is held to unless a caller asks for others.
    package static let standard = Self(maxSpecBytes: 65_536, maxSteps: 32, maxFileBytes: 65_536, maxDepth: 8)
}

/// Why a spec, a script file or a seed was refused, with the line of the spec it concerns when there is one.
package struct ProvisioningError: Error, Equatable, CustomStringConvertible {
    /// The 1-based line of the spec, or nil when the whole input is concerned (its size, an empty spec).
    package let line: Int?
    package let message: String

    init(line: Int?, _ message: String) {
        self.line = line
        self.message = message
    }

    package var description: String {
        guard let line else { return message }
        return "line \(line): \(message)"
    }
}
